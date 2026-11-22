// SPDX-License-Identifier: GPL-2.0-only

/* Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries. */

/*
 * Sahara image loader for flashless modems on the MHI bus.
 *
 * Based on the Sahara implementation of the qaic driver
 * (drivers/accel/qaic/sahara.c), with the image table of the SDX55.
 *
 * Copyright (c) 2024-2026 Timo <1788603+darknagel@users.noreply.github.com>
 */

#include <linux/atomic.h>
#include <linux/firmware.h>
#include <linux/limits.h>
#include <linux/mhi.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/overflow.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/workqueue.h>


#define SAHARA_HELLO_CMD		0x1  /* Min protocol version 1.0 */
#define SAHARA_HELLO_RESP_CMD		0x2  /* Min protocol version 1.0 */
#define SAHARA_READ_DATA_CMD		0x3  /* Min protocol version 1.0 */
#define SAHARA_END_OF_IMAGE_CMD		0x4  /* Min protocol version 1.0 */
#define SAHARA_DONE_CMD			0x5  /* Min protocol version 1.0 */
#define SAHARA_DONE_RESP_CMD		0x6  /* Min protocol version 1.0 */
#define SAHARA_RESET_CMD		0x7  /* Min protocol version 1.0 */
#define SAHARA_RESET_RESP_CMD		0x8  /* Min protocol version 1.0 */
#define SAHARA_MEM_DEBUG_CMD		0x9  /* Min protocol version 2.0 */
#define SAHARA_MEM_READ_CMD		0xa  /* Min protocol version 2.0 */
#define SAHARA_CMD_READY_CMD		0xb  /* Min protocol version 2.1 */
#define SAHARA_SWITCH_MODE_CMD		0xc  /* Min protocol version 2.1 */
#define SAHARA_EXECUTE_CMD		0xd  /* Min protocol version 2.1 */
#define SAHARA_EXECUTE_RESP_CMD		0xe  /* Min protocol version 2.1 */
#define SAHARA_EXECUTE_DATA_CMD		0xf  /* Min protocol version 2.1 */
#define SAHARA_MEM_DEBUG64_CMD		0x10 /* Min protocol version 2.5 */
#define SAHARA_MEM_READ64_CMD		0x11 /* Min protocol version 2.5 */
#define SAHARA_READ_DATA64_CMD		0x12 /* Min protocol version 2.8 */
#define SAHARA_RESET_STATE_CMD		0x13 /* Min protocol version 2.9 */
#define SAHARA_WRITE_DATA_CMD		0x14 /* Min protocol version 3.0 */

#define SAHARA_PACKET_MAX_SIZE		0xffffU /* MHI_MAX_MTU */
/*
 * Size of one batch of a READ_DATA response. The SDX55 SBL requests up to a
 * whole ELF segment at a time; larger requests are sent in several batches.
 */
#define SAHARA_TRANSFER_MAX_SIZE	0x800000
#define SAHARA_READ_MAX_SIZE		0xfff0U /* Avoid unaligned requests */
#define SAHARA_NUM_TX_BUF		DIV_ROUND_UP(SAHARA_TRANSFER_MAX_SIZE,\
							SAHARA_PACKET_MAX_SIZE)
#define SAHARA_IMAGE_ID_NONE		U32_MAX

#define SAHARA_VERSION			2
#define SAHARA_SUCCESS			0
#define SAHARA_TABLE_ENTRY_STR_LEN	20

#define SAHARA_MODE_IMAGE_TX_PENDING	0x0
#define SAHARA_MODE_IMAGE_TX_COMPLETE	0x1
#define SAHARA_MODE_MEMORY_DEBUG	0x2
#define SAHARA_MODE_COMMAND		0x3

#define SAHARA_HELLO_LENGTH		0x30
#define SAHARA_READ_DATA_LENGTH		0x14
#define SAHARA_END_OF_IMAGE_LENGTH	0x10
#define SAHARA_DONE_LENGTH		0x8
#define SAHARA_RESET_LENGTH		0x8
#define SAHARA_MEM_DEBUG_LENGTH		0x10
#define SAHARA_MEM_READ_LENGTH		0x10
#define SAHARA_MEM_DEBUG64_LENGTH	0x18
#define SAHARA_MEM_READ64_LENGTH	0x18
#define SAHARA_CMD_READY_LENGTH		0x8
#define SAHARA_SWITCH_MODE_LENGTH	0xc

/*
 * Upper bound for command mode entries without image transfer progress in
 * between. The host answers every command ready packet with a mode switch
 * back to the image transfer mode; a modem that keeps asking for the
 * command mode again would otherwise loop forever.
 */
#define SAHARA_MAX_CMD_MODE_ENTRIES	4

struct sahara_packet {
	__le32 cmd;
	__le32 length;

	union {
		struct {
			__le32 version;
			__le32 version_compat;
			__le32 max_length;
			__le32 mode;
		} hello;
		struct {
			__le32 version;
			__le32 version_compat;
			__le32 status;
			__le32 mode;
		} hello_resp;
		struct {
			__le32 image;
			__le32 offset;
			__le32 length;
		} read_data;
		struct {
			__le32 image;
			__le32 status;
		} end_of_image;
		struct {
			__le32 table_address;
			__le32 table_length;
		} memory_debug;
		struct {
			__le32 memory_address;
			__le32 memory_length;
		} memory_read;
		struct {
			__le64 table_address;
			__le64 table_length;
		} memory_debug64;
		struct {
			__le64 memory_address;
			__le64 memory_length;
		} memory_read64;
		struct {
			__le32 mode;
		} switch_mode;
	};
};

struct sahara_debug_table_entry64 {
	__le64	type;
	__le64	address;
	__le64	length;
	char	description[SAHARA_TABLE_ENTRY_STR_LEN];
	char	filename[SAHARA_TABLE_ENTRY_STR_LEN];
};

struct sahara_debug_table_entry32 {
	__le32	type;
	__le32	address;
	__le32	length;
	char	description[SAHARA_TABLE_ENTRY_STR_LEN];
	char	filename[SAHARA_TABLE_ENTRY_STR_LEN];
};

/* One range of the modem memory the modem asks us to read out */
struct sahara_image_range {
	u64	address;
	u64	length;
};

struct sahara_context {
	struct sahara_packet		*tx[SAHARA_NUM_TX_BUF];
	struct sahara_packet		*rx;
	struct work_struct		fw_work;
	struct work_struct		dump_work;
	struct work_struct		read_data_work;
	struct mhi_device		*mhi_dev;
	const char * const		*image_table;
	u32				table_size;
	u32				active_image_id;
	const struct firmware		*firmware;
	u64				dump_table_address;
	u64				dump_table_length;
	struct sahara_image_range	*dump_ranges;
	u32				dump_ranges_count;
	u32				dump_range_index;
	u64				dump_range_offset;
	size_t				rx_size;
	size_t				rx_size_requested;
	u32				read_data_offset;
	u32				read_data_length;
	atomic_t			tx_done;
	unsigned int			tx_batch;
	unsigned int			cmd_mode_entries;
	bool				is_mem_dump_mode;
	bool				mem32;
	bool				non_streaming;
};

/* Image IDs requested by the SDX55 SBL, as served by the vendor image loader */
static const char * const sdx55_image_table[] = {
	[6]  = "qcom/sdx55m/apps.mbn",
	[8]  = "qcom/sdx55m/qdsp6sw.mbn",
	[16] = "qcom/sdx55m/efs1.bin",
	[17] = "qcom/sdx55m/efs2.bin",
	[20] = "qcom/sdx55m/efs3.bin",
	[21] = "qcom/sdx55m/sbl1.mbn",
	[23] = "qcom/sdx55m/aop.mbn",
	[25] = "qcom/sdx55m/tz.mbn",
	[29] = "qcom/sdx55m/acdb.mbn",
	[33] = "qcom/sdx55m/hyp.mbn",
	[34] = "qcom/sdx55m/mdmddr.mbn",
	[36] = "qcom/sdx55m/multi_image_qti.mbn",
	[37] = "qcom/sdx55m/multi_image.mbn",
	[38] = "qcom/sdx55m/xbl_cfg.elf",
	[40] = "qcom/sdx55m/apdp.mbn",
	[41] = "qcom/sdx55m/devcfg.mbn",
	[42] = "qcom/sdx55m/sec.elf",
};

static bool is_streaming(struct sahara_context *context)
{
	return !context->non_streaming;
}

static int sahara_find_image(struct sahara_context *context, u32 image_id)
{
	int ret;

	if (image_id == context->active_image_id)
		return 0;

	if (context->active_image_id != SAHARA_IMAGE_ID_NONE) {
		dev_err(&context->mhi_dev->dev, "image id %d is not valid as %d is active\n",
			image_id, context->active_image_id);
		return -EINVAL;
	}

	if (image_id >= context->table_size || !context->image_table[image_id]) {
		dev_err(&context->mhi_dev->dev, "request for unknown image: %d\n", image_id);
		return -EINVAL;
	}

	/*
	 * This image might be optional. The device may continue without it.
	 * Only the device knows. Suppress error messages that could suggest an
	 * a problem when we were actually able to continue.
	 */
	ret = firmware_request_nowarn(&context->firmware,
				      context->image_table[image_id],
				      &context->mhi_dev->dev);
	if (ret) {
		dev_err(&context->mhi_dev->dev, "request for image id %d / file %s failed %d\n",
			image_id, context->image_table[image_id], ret);
		return ret;
	}

	context->active_image_id = image_id;
	/* Progress: the modem asked for an image, so it is not stuck. */
	context->cmd_mode_entries = 0;
	dev_info(&context->mhi_dev->dev, "image %u: %s (%zu bytes)\n", image_id,
		 context->image_table[image_id], context->firmware->size);

	return 0;
}

static void sahara_release_image(struct sahara_context *context)
{
	if (context->active_image_id != SAHARA_IMAGE_ID_NONE)
		release_firmware(context->firmware);
	context->active_image_id = SAHARA_IMAGE_ID_NONE;
}

static void sahara_send_reset(struct sahara_context *context)
{
	int ret;

	context->is_mem_dump_mode = false;
	context->mem32 = false;
	context->read_data_offset = 0;
	context->read_data_length = 0;

	context->tx[0]->cmd = cpu_to_le32(SAHARA_RESET_CMD);
	context->tx[0]->length = cpu_to_le32(SAHARA_RESET_LENGTH);

	ret = mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE, context->tx[0],
			    SAHARA_RESET_LENGTH, MHI_EOT);
	if (ret)
		dev_err(&context->mhi_dev->dev, "Unable to send reset response %d\n", ret);
}

static void sahara_hello(struct sahara_context *context)
{
	int ret;

	dev_dbg(&context->mhi_dev->dev,
		"HELLO cmd received. length:%d version:%d version_compat:%d max_length:%d mode:%d\n",
		le32_to_cpu(context->rx->length),
		le32_to_cpu(context->rx->hello.version),
		le32_to_cpu(context->rx->hello.version_compat),
		le32_to_cpu(context->rx->hello.max_length),
		le32_to_cpu(context->rx->hello.mode));

	if (le32_to_cpu(context->rx->length) != SAHARA_HELLO_LENGTH) {
		dev_err(&context->mhi_dev->dev, "Malformed hello packet - length %d\n",
			le32_to_cpu(context->rx->length));
		return;
	}
	if (le32_to_cpu(context->rx->hello.version) != SAHARA_VERSION) {
		dev_err(&context->mhi_dev->dev, "Unsupported hello packet - version %d\n",
			le32_to_cpu(context->rx->hello.version));
		return;
	}

	if (le32_to_cpu(context->rx->hello.mode) != SAHARA_MODE_IMAGE_TX_PENDING &&
	    le32_to_cpu(context->rx->hello.mode) != SAHARA_MODE_IMAGE_TX_COMPLETE &&
	    le32_to_cpu(context->rx->hello.mode) != SAHARA_MODE_MEMORY_DEBUG &&
	    le32_to_cpu(context->rx->hello.mode) != SAHARA_MODE_COMMAND) {
		dev_err(&context->mhi_dev->dev, "Unsupported hello packet - mode %d\n",
			le32_to_cpu(context->rx->hello.mode));
		return;
	}

	/*
	 * The mode of the hello response tells the modem in which mode it has
	 * to operate. The reference implementations of the protocol answer a
	 * hello with the mode that the modem asked for, also with the command
	 * mode: after that response the modem sends a command ready packet
	 * (0xB) and waits for client commands from the host. Rejecting the
	 * command mode instead of answering it leaves the modem waiting: the
	 * SDX55 SBL announces the command mode after the last image and the
	 * boot does not continue.
	 */
	context->tx[0]->cmd = cpu_to_le32(SAHARA_HELLO_RESP_CMD);
	context->tx[0]->length = cpu_to_le32(SAHARA_HELLO_LENGTH);
	context->tx[0]->hello_resp.version = cpu_to_le32(SAHARA_VERSION);
	context->tx[0]->hello_resp.version_compat = cpu_to_le32(SAHARA_VERSION);
	context->tx[0]->hello_resp.status = cpu_to_le32(SAHARA_SUCCESS);
	context->tx[0]->hello_resp.mode = context->rx->hello_resp.mode;

	ret = mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE, context->tx[0],
			    SAHARA_HELLO_LENGTH, MHI_EOT);
	if (ret)
		dev_err(&context->mhi_dev->dev, "Unable to send hello response %d\n", ret);
}

/*
 * The modem announces that it is ready to execute client commands. The
 * host answers with a mode switch back to the image transfer mode: the
 * modem leaves the command mode and issues a new hello packet, so the boot
 * continues with the image load flow. No client command is executed, so no
 * calibration or memory content of the modem is read out or changed.
 */
static void sahara_command_ready(struct sahara_context *context)
{
	int ret;

	if (le32_to_cpu(context->rx->length) != SAHARA_CMD_READY_LENGTH) {
		dev_err(&context->mhi_dev->dev,
			"Malformed command ready packet - length %d\n",
			le32_to_cpu(context->rx->length));
		return;
	}

	if (++context->cmd_mode_entries > SAHARA_MAX_CMD_MODE_ENTRIES) {
		/*
		 * The modem keeps asking for the command mode without making
		 * progress. Do not reset it here: the modem re-enters the
		 * command mode on its own after the last image, so a reset
		 * would only start the exchange again. Stop switching the
		 * mode instead and leave the modem in the command mode, where
		 * it waits for a client command.
		 */
		dev_err(&context->mhi_dev->dev,
			"Modem asks for the command mode too often, staying in it\n");
		return;
	}

	dev_info(&context->mhi_dev->dev,
		 "modem is ready for client commands, returning to image transfer\n");

	context->tx[0]->cmd = cpu_to_le32(SAHARA_SWITCH_MODE_CMD);
	context->tx[0]->length = cpu_to_le32(SAHARA_SWITCH_MODE_LENGTH);
	context->tx[0]->switch_mode.mode = cpu_to_le32(SAHARA_MODE_IMAGE_TX_PENDING);

	ret = mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE, context->tx[0],
			    SAHARA_SWITCH_MODE_LENGTH, MHI_EOT);
	if (ret)
		dev_err(&context->mhi_dev->dev, "Unable to send mode switch %d\n", ret);
}

static int read_data_helper(struct sahara_context *context, int buf_index,
			    bool last_in_batch)
{
	enum mhi_flags mhi_flag;
	u32 pkt_data_len;
	int ret;

	pkt_data_len = min(context->read_data_length, SAHARA_PACKET_MAX_SIZE);

	memcpy(context->tx[buf_index],
	       &context->firmware->data[context->read_data_offset],
	       pkt_data_len);

	context->read_data_offset += pkt_data_len;
	context->read_data_length -= pkt_data_len;

	if (is_streaming(context) || !context->read_data_length || last_in_batch)
		mhi_flag = MHI_EOT;
	else
		mhi_flag = MHI_CHAIN;

	ret = mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE,
			    context->tx[buf_index], pkt_data_len, mhi_flag);
	if (ret) {
		dev_err(&context->mhi_dev->dev, "Unable to send read_data response %d\n", ret);
		return ret;
	}

	return 0;
}

/*
 * Queue the next batch of a READ_DATA response: as many chained buffers as
 * there are, the last one with EOT. The next batch follows once the device
 * has consumed all of them, see sahara_mhi_ul_xfer_cb().
 */
static void sahara_send_batch(struct sahara_context *context)
{
	unsigned int n;

	n = min_t(unsigned int, SAHARA_NUM_TX_BUF,
		  DIV_ROUND_UP(context->read_data_length, SAHARA_PACKET_MAX_SIZE));
	/* A batch must fit into the transfer ring */
	n = min_t(unsigned int, n,
		  mhi_get_free_desc_count(context->mhi_dev, DMA_TO_DEVICE));
	if (!n) {
		dev_err(&context->mhi_dev->dev, "No room in the transfer ring\n");
		return;
	}

	atomic_set(&context->tx_done, 0);
	context->tx_batch = n;

	for (unsigned int i = 0; i < n; ++i) {
		if (read_data_helper(context, i, i == n - 1)) {
			context->tx_batch = 0;
			break;
		}
	}
}

static void sahara_read_data(struct sahara_context *context)
{
	u32 image_id, data_offset, data_len;
	int ret;

	dev_dbg(&context->mhi_dev->dev,
		"READ_DATA cmd received. length:%d image:%d offset:%d data_length:%d\n",
		le32_to_cpu(context->rx->length),
		le32_to_cpu(context->rx->read_data.image),
		le32_to_cpu(context->rx->read_data.offset),
		le32_to_cpu(context->rx->read_data.length));

	if (le32_to_cpu(context->rx->length) != SAHARA_READ_DATA_LENGTH) {
		dev_err(&context->mhi_dev->dev, "Malformed read_data packet - length %d\n",
			le32_to_cpu(context->rx->length));
		return;
	}

	image_id = le32_to_cpu(context->rx->read_data.image);
	data_offset = le32_to_cpu(context->rx->read_data.offset);
	data_len = le32_to_cpu(context->rx->read_data.length);

	ret = sahara_find_image(context, image_id);
	if (ret) {
		sahara_send_reset(context);
		return;
	}

	/*
	 * Image is released when the device is done with it via
	 * SAHARA_END_OF_IMAGE_CMD. sahara_send_reset() will either cause the
	 * device to retry the operation with a modification, or decide to be
	 * done with the image and trigger SAHARA_END_OF_IMAGE_CMD.
	 * release_image() is called from SAHARA_END_OF_IMAGE_CMD. processing
	 * and is not needed here on error.
	 */

	if (data_offset >= context->firmware->size) {
		dev_err(&context->mhi_dev->dev, "Malformed read_data packet - data offset %d exceeds file size %zu\n",
			data_offset, context->firmware->size);
		sahara_send_reset(context);
		return;
	}

	if (size_add(data_offset, data_len) > context->firmware->size) {
		dev_err(&context->mhi_dev->dev, "Malformed read_data packet - data offset %d and length %d exceeds file size %zu\n",
			data_offset, data_len, context->firmware->size);
		sahara_send_reset(context);
		return;
	}

	context->read_data_offset = data_offset;
	context->read_data_length = data_len;

	if (is_streaming(context)) {
		schedule_work(&context->read_data_work);
		return;
	}

	sahara_send_batch(context);
}

static void sahara_end_of_image(struct sahara_context *context)
{
	int ret;

	dev_dbg(&context->mhi_dev->dev,
		"END_OF_IMAGE cmd received. length:%d image:%d status:%d\n",
		le32_to_cpu(context->rx->length),
		le32_to_cpu(context->rx->end_of_image.image),
		le32_to_cpu(context->rx->end_of_image.status));

	if (le32_to_cpu(context->rx->length) != SAHARA_END_OF_IMAGE_LENGTH) {
		dev_err(&context->mhi_dev->dev, "Malformed end_of_image packet - length %d\n",
			le32_to_cpu(context->rx->length));
		return;
	}

	if (context->active_image_id != SAHARA_IMAGE_ID_NONE &&
	    le32_to_cpu(context->rx->end_of_image.image) != context->active_image_id) {
		dev_err(&context->mhi_dev->dev, "Malformed end_of_image packet - image %d is not the active image\n",
			le32_to_cpu(context->rx->end_of_image.image));
		return;
	}

	sahara_release_image(context);

	if (le32_to_cpu(context->rx->end_of_image.status))
		return;

	context->tx[0]->cmd = cpu_to_le32(SAHARA_DONE_CMD);
	context->tx[0]->length = cpu_to_le32(SAHARA_DONE_LENGTH);

	ret = mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE, context->tx[0],
			    SAHARA_DONE_LENGTH, MHI_EOT);
	if (ret)
		dev_dbg(&context->mhi_dev->dev, "Unable to send done response %d\n", ret);
}

/*
 * Request a chunk of the modem's memory in the width the modem asked for.
 * The read-out is a transfer in the opposite direction, it is received as raw
 * data in sahara_dump_processing().
 */
static int sahara_send_mem_read(struct sahara_context *context, u64 addr, u64 len)
{
	if (context->mem32) {
		context->tx[0]->cmd = cpu_to_le32(SAHARA_MEM_READ_CMD);
		context->tx[0]->length = cpu_to_le32(SAHARA_MEM_READ_LENGTH);
		context->tx[0]->memory_read.memory_address = cpu_to_le32(addr);
		context->tx[0]->memory_read.memory_length = cpu_to_le32(len);
		return mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE, context->tx[0],
				     SAHARA_MEM_READ_LENGTH, MHI_EOT);
	}

	context->tx[0]->cmd = cpu_to_le32(SAHARA_MEM_READ64_CMD);
	context->tx[0]->length = cpu_to_le32(SAHARA_MEM_READ64_LENGTH);
	context->tx[0]->memory_read64.memory_address = cpu_to_le64(addr);
	context->tx[0]->memory_read64.memory_length = cpu_to_le64(len);
	return mhi_queue_buf(context->mhi_dev, DMA_TO_DEVICE, context->tx[0],
			     SAHARA_MEM_READ64_LENGTH, MHI_EOT);
}

/*
 * The modem asks for a dump of its own memory, described by a table of image
 * ranges. The exchange has to be carried out to completion, the modem resets
 * itself when it does not get an answer. Only the geometry of the request is
 * of interest here: the ranges are read out and their content is dropped on
 * arrival, so that no part of the modem's memory can reach the log or a file.
 */
static int sahara_dump_begin(struct sahara_context *context, u64 table_addr,
			     u64 table_len)
{
	context->dump_table_address = table_addr;
	context->dump_table_length = table_len;

	if (!table_len || table_len > SAHARA_PACKET_MAX_SIZE ||
	    table_len % (context->mem32 ?
			 sizeof(struct sahara_debug_table_entry32) :
			 sizeof(struct sahara_debug_table_entry64))) {
		dev_err(&context->mhi_dev->dev, "Bad memory debug table length %llu\n",
			table_len);
		return -EINVAL;
	}

	kfree(context->dump_ranges);
	context->dump_ranges = NULL;
	context->dump_ranges_count = 0;
	context->dump_range_index = 0;
	context->dump_range_offset = 0;

	context->is_mem_dump_mode = true;
	context->rx_size_requested = table_len;

	return sahara_send_mem_read(context, table_addr, table_len);
}

static void sahara_memory_debug(struct sahara_context *context)
{
	int ret;

	dev_dbg(&context->mhi_dev->dev,
		"MEMORY DEBUG cmd received. length:%d table_address:%x table_length:%x\n",
		le32_to_cpu(context->rx->length),
		le32_to_cpu(context->rx->memory_debug.table_address),
		le32_to_cpu(context->rx->memory_debug.table_length));

	if (le32_to_cpu(context->rx->length) != SAHARA_MEM_DEBUG_LENGTH) {
		dev_err(&context->mhi_dev->dev, "Malformed memory debug packet - length %d\n",
			le32_to_cpu(context->rx->length));
		return;
	}

	context->mem32 = true;
	ret = sahara_dump_begin(context,
				le32_to_cpu(context->rx->memory_debug.table_address),
				le32_to_cpu(context->rx->memory_debug.table_length));
	if (ret)
		sahara_send_reset(context);
}

static void sahara_memory_debug64(struct sahara_context *context)
{
	int ret;

	dev_dbg(&context->mhi_dev->dev,
		"MEMORY DEBUG64 cmd received. length:%d table_address:%#llx table_length:%#llx\n",
		le32_to_cpu(context->rx->length),
		le64_to_cpu(context->rx->memory_debug64.table_address),
		le64_to_cpu(context->rx->memory_debug64.table_length));

	if (le32_to_cpu(context->rx->length) != SAHARA_MEM_DEBUG64_LENGTH) {
		dev_err(&context->mhi_dev->dev, "Malformed memory debug64 packet - length %d\n",
			le32_to_cpu(context->rx->length));
		return;
	}

	context->mem32 = false;
	ret = sahara_dump_begin(context,
				le64_to_cpu(context->rx->memory_debug64.table_address),
				le64_to_cpu(context->rx->memory_debug64.table_length));
	if (ret)
		sahara_send_reset(context);
}

static void sahara_processing(struct work_struct *work)
{
	struct sahara_context *context = container_of(work, struct sahara_context, fw_work);
	int ret;

	switch (le32_to_cpu(context->rx->cmd)) {
	case SAHARA_HELLO_CMD:
		sahara_hello(context);
		break;
	case SAHARA_READ_DATA_CMD:
		sahara_read_data(context);
		break;
	case SAHARA_END_OF_IMAGE_CMD:
		sahara_end_of_image(context);
		break;
	case SAHARA_DONE_RESP_CMD:
		/* Intentional do nothing as we don't need to exit an app */
		break;
	case SAHARA_RESET_RESP_CMD:
		/* Intentional do nothing as we don't need to exit an app */
		break;
	case SAHARA_MEM_DEBUG64_CMD:
		sahara_memory_debug64(context);
		break;
	case SAHARA_MEM_DEBUG_CMD:
		sahara_memory_debug(context);
		break;
	case SAHARA_CMD_READY_CMD:
		sahara_command_ready(context);
		break;
	default:
		dev_err(&context->mhi_dev->dev, "Unknown command %d\n",
			le32_to_cpu(context->rx->cmd));
		break;
	}

	ret = mhi_queue_buf(context->mhi_dev, DMA_FROM_DEVICE, context->rx,
			    SAHARA_PACKET_MAX_SIZE, MHI_EOT);
	if (ret)
		dev_err(&context->mhi_dev->dev, "Unable to requeue rx buf %d\n", ret);
}

/* Ask the modem for the next chunk of the range that is currently read out */
static void sahara_dump_next(struct sahara_context *context)
{
	struct sahara_image_range *range;
	u64 chunk;

	/* Skip ranges the modem listed as empty */
	while (context->dump_range_index < context->dump_ranges_count) {
		range = &context->dump_ranges[context->dump_range_index];

		if (context->dump_range_offset < range->length)
			break;

		context->dump_range_index++;
		context->dump_range_offset = 0;
	}

	if (context->dump_range_index >= context->dump_ranges_count) {
		dev_info(&context->mhi_dev->dev,
			 "memory debug transfer complete\n");
		sahara_send_reset(context);
		return;
	}

	range = &context->dump_ranges[context->dump_range_index];

	chunk = min_t(u64, range->length - context->dump_range_offset,
		      SAHARA_READ_MAX_SIZE);
	/* Avoid requesting EOI sized data so that we can identify errors */
	if (chunk == SAHARA_END_OF_IMAGE_LENGTH)
		chunk = SAHARA_END_OF_IMAGE_LENGTH / 2;

	context->rx_size_requested = chunk;

	if (sahara_send_mem_read(context, range->address + context->dump_range_offset,
				 chunk)) {
		dev_err(&context->mhi_dev->dev, "Unable to send read for dump content\n");
		sahara_send_reset(context);
	}
}

/*
 * The modem sent the table of the ranges it wants read out. Note the ranges,
 * but not their names: they may carry information about the modem's state
 * that must not leave the device.
 */
static int sahara_parse_dump_table(struct sahara_context *context)
{
	struct sahara_image_range *ranges;
	u64 nents, total = 0, i;

	nents = context->dump_table_length / (context->mem32 ?
			sizeof(struct sahara_debug_table_entry32) :
			sizeof(struct sahara_debug_table_entry64));

	ranges = kmalloc_array(nents, sizeof(*ranges), GFP_KERNEL);
	if (!ranges)
		return -ENOMEM;

	if (context->mem32) {
		struct sahara_debug_table_entry32 *table =
			(struct sahara_debug_table_entry32 *)context->rx;

		for (i = 0; i < nents; ++i) {
			ranges[i].address = le32_to_cpu(table[i].address);
			ranges[i].length = le32_to_cpu(table[i].length);
			total += ranges[i].length;
		}
	} else {
		struct sahara_debug_table_entry64 *table =
			(struct sahara_debug_table_entry64 *)context->rx;

		for (i = 0; i < nents; ++i) {
			ranges[i].address = le64_to_cpu(table[i].address);
			ranges[i].length = le64_to_cpu(table[i].length);
			total += ranges[i].length;
		}
	}

	kfree(context->dump_ranges);
	context->dump_ranges = ranges;
	context->dump_ranges_count = nents;
	context->dump_range_index = 0;
	context->dump_range_offset = 0;

	dev_info(&context->mhi_dev->dev,
		 "memory debug table: %llu ranges, %llu bytes in total\n",
		 nents, total);

	return 0;
}

static void sahara_dump_processing(struct work_struct *work)
{
	struct sahara_context *context = container_of(work, struct sahara_context, dump_work);
	int ret;
	bool is_table;

	/*
	 * We should get the expected raw data, but if the device has an error
	 * it is supposed to send EOI with an error code.
	 */
	if (context->rx_size != context->rx_size_requested &&
	    context->rx_size != SAHARA_END_OF_IMAGE_LENGTH) {
		dev_err(&context->mhi_dev->dev,
			"Unexpected response to read_data. Expected size: %#zx got: %#zx\n",
			context->rx_size_requested,
			context->rx_size);
		goto error;
	}

	if (context->rx_size == SAHARA_END_OF_IMAGE_LENGTH) {
		dev_err(&context->mhi_dev->dev,
			"EOI response to a memory read, status: %d\n",
			le32_to_cpu(context->rx->end_of_image.status));
		goto error;
	}

	/*
	 * Need to know if we received the dump table, or part of a dump image.
	 * Since we get raw data, we cannot tell from the data itself. Instead,
	 * we use the stored dump_table_length, which we zero after we read and
	 * process the entire table.
	 */
	is_table = context->dump_table_length != 0;

	if (is_table && sahara_parse_dump_table(context))
		goto error;

	/*
	 * Give the buffer back before the answer to the request arrives: the
	 * modem may start sending the next chunk at once.
	 */
	ret = mhi_queue_buf(context->mhi_dev, DMA_FROM_DEVICE, context->rx,
			    SAHARA_PACKET_MAX_SIZE, MHI_EOT);
	if (ret) {
		dev_err(&context->mhi_dev->dev, "Unable to requeue rx buf %d\n", ret);
		sahara_send_reset(context);
		return;
	}

	/* The content of every chunk is dropped, only its arrival is counted */
	if (!is_table)
		context->dump_range_offset += context->rx_size_requested;

	context->dump_table_length = 0;
	sahara_dump_next(context);
	return;

error:
	sahara_send_reset(context);
	ret = mhi_queue_buf(context->mhi_dev, DMA_FROM_DEVICE, context->rx,
			    SAHARA_PACKET_MAX_SIZE, MHI_EOT);
	if (ret)
		dev_err(&context->mhi_dev->dev, "Unable to requeue rx buf %d\n", ret);
}

static void sahara_read_data_processing(struct work_struct *work)
{
	struct sahara_context *context = container_of(work, struct sahara_context, read_data_work);

	if (is_streaming(context))
		read_data_helper(context, 0, true);
	else
		sahara_send_batch(context);
}

static int sahara_mhi_probe(struct mhi_device *mhi_dev, const struct mhi_device_id *id)
{
	struct sahara_context *context;
	int ret;
	int i;

	context = devm_kzalloc(&mhi_dev->dev, sizeof(*context), GFP_KERNEL);
	if (!context)
		return -ENOMEM;

	context->rx = devm_kzalloc(&mhi_dev->dev, SAHARA_PACKET_MAX_SIZE, GFP_KERNEL);
	if (!context->rx)
		return -ENOMEM;

	/* The SDX55 SBL defines a Sahara transfer size, like AIC100 */
	context->image_table = sdx55_image_table;
	context->table_size = ARRAY_SIZE(sdx55_image_table);
	context->non_streaming = true;

	/*
	 * There are two firmware implementations for READ_DATA handling.
	 * The older "SBL" implementation defines a Sahara transfer size, and
	 * expects that the response is a single transport transfer. If the
	 * FW wants to transfer a file that is larger than the transfer size,
	 * the FW will issue multiple READ_DATA commands. For this
	 * implementation, we need to allocate enough buffers to contain the
	 * entire Sahara transfer size.
	 *
	 * The newer "XBL" implementation does not define a maximum transfer
	 * size and instead expects the data to be streamed over using the
	 * transport level MTU. The FW will issue a single READ_DATA command
	 * of whatever size, and consume multiple transport level transfers
	 * until the expected amount of data is consumed. For this
	 * implementation we only need a single buffer of the transport MTU
	 * but we'll need to be able to use it multiple times for a single
	 * READ_DATA request.
	 *
	 * AIC100 is the SBL implementation and defines SAHARA_TRANSFER_MAX_SIZE
	 * and we need 9x SAHARA_PACKET_MAX_SIZE to cover that. We can use
	 * MHI_CHAIN to link multiple buffers into a single transfer but the
	 * remote side will not consume the buffers until it sees an EOT, thus
	 * we need to allocate enough buffers to put in the tx fifo to cover an
	 * entire READ_DATA request of the max size.
	 *
	 * AIC200 is the XBL implementation, and so a single buffer will work.
	 */
	for (i = 0; i < SAHARA_NUM_TX_BUF; ++i) {
		context->tx[i] = devm_kzalloc(&mhi_dev->dev,
					      SAHARA_PACKET_MAX_SIZE,
					      GFP_KERNEL);
		if (!context->tx[i])
			return -ENOMEM;
		if (is_streaming(context))
			break;
	}

	context->mhi_dev = mhi_dev;
	INIT_WORK(&context->fw_work, sahara_processing);
	INIT_WORK(&context->dump_work, sahara_dump_processing);
	INIT_WORK(&context->read_data_work, sahara_read_data_processing);

	context->active_image_id = SAHARA_IMAGE_ID_NONE;
	dev_set_drvdata(&mhi_dev->dev, context);

	ret = mhi_prepare_for_transfer(mhi_dev);
	if (ret)
		return ret;

	ret = mhi_queue_buf(mhi_dev, DMA_FROM_DEVICE, context->rx, SAHARA_PACKET_MAX_SIZE, MHI_EOT);
	if (ret) {
		mhi_unprepare_from_transfer(mhi_dev);
		return ret;
	}

	dev_info(&mhi_dev->dev, "sahara image loader attached\n");

	return 0;
}

static void sahara_mhi_remove(struct mhi_device *mhi_dev)
{
	struct sahara_context *context = dev_get_drvdata(&mhi_dev->dev);

	cancel_work_sync(&context->fw_work);
	cancel_work_sync(&context->dump_work);
	cancel_work_sync(&context->read_data_work);
	kfree(context->dump_ranges);
	sahara_release_image(context);
	mhi_unprepare_from_transfer(mhi_dev);
}

static void sahara_mhi_ul_xfer_cb(struct mhi_device *mhi_dev, struct mhi_result *mhi_result)
{
	struct sahara_context *context = dev_get_drvdata(&mhi_dev->dev);

	if (!mhi_result->transaction_status && context->read_data_length && is_streaming(context))
		schedule_work(&context->read_data_work);

	/* Last buffer of a batch consumed, send the next batch */
	if (!is_streaming(context) && context->tx_batch &&
	    atomic_inc_return(&context->tx_done) == context->tx_batch) {
		context->tx_batch = 0;
		if (context->read_data_length)
			schedule_work(&context->read_data_work);
	}
}

static void sahara_mhi_dl_xfer_cb(struct mhi_device *mhi_dev, struct mhi_result *mhi_result)
{
	struct sahara_context *context = dev_get_drvdata(&mhi_dev->dev);

	if (!mhi_result->transaction_status) {
		context->rx_size = mhi_result->bytes_xferd;
		if (context->is_mem_dump_mode)
			schedule_work(&context->dump_work);
		else
			schedule_work(&context->fw_work);
	}

}

static const struct mhi_device_id sahara_mhi_match_table[] = {
	{ .chan = "SAHARA", },
	{},
};
MODULE_DEVICE_TABLE(mhi, sahara_mhi_match_table);

static struct mhi_driver sahara_mhi_driver = {
	.id_table = sahara_mhi_match_table,
	.remove = sahara_mhi_remove,
	.probe = sahara_mhi_probe,
	.ul_xfer_cb = sahara_mhi_ul_xfer_cb,
	.dl_xfer_cb = sahara_mhi_dl_xfer_cb,
	.driver = {
		.name = "mhi-sahara",
	},
};

module_mhi_driver(sahara_mhi_driver);

MODULE_DESCRIPTION("Sahara image loader for flashless MHI modems");
MODULE_LICENSE("GPL");
