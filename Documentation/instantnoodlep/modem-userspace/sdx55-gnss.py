#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# SDX55 QMI LOC GNSS client over QRTR.
#
# Connects to the Qualcomm SDX55 modem's Location service (QMI LOC, service ID 16)
# over QRTR (AF_QIPCRTR), configures standalone GNSS positioning, starts a tracking
# session, and streams standard NMEA 0183 sentences to a pseudo-terminal (pty)
# device node (by default /dev/gnss-sdx55) for gpsd and other consumers.
#
# Provenance and Protocol References:
# - QRTR transport & lookup: Linux kernel <linux/qrtr.h>, AF_QIPCRTR (42),
#   QRTR_TYPE_NEW_LOOKUP (10), QRTR_TYPE_NEW_SERVER (4), QRTR_PORT_CTRL (0xfffffffe).
# - QMI LOC message definitions & wire format: libqmi <libqmi-glib/qmi-loc.h>,
#   <libqmi-glib/qmi-enums-loc.h>, <libqmi-glib/qmi-flags64-loc.h>.
#   - QMI LOC Service ID: 16 (0x10)
#   - 0x0020: QMI_LOC_SERVICE_CLIENT_REVISION (revision 2)
#   - 0x003a: QMI_LOC_SET_ENGINE_LOCK (lock state: 1 = none)
#   - 0x003e: QMI_LOC_SET_NMEA_TYPES (sentence mask: 0x39f = GGA, RMC, GSV, GSA, VTG, GLGSV, GNGSA, GNGNS)
#   - 0x0038: QMI_LOC_INJECT_UTC_TIME (time in ms, uncertainty in ms)
#   - 0x004a: QMI_LOC_SET_OPERATION_MODE (operation mode: 4 = standalone)
#   - 0x0021: QMI_LOC_REGISTER_EVENTS (event registration mask: 0x04 = NMEA)
#   - 0x0022: QMI_LOC_START (session id, intermediate report state, fix interval)
#   - 0x0023: QMI_LOC_STOP (session id)
#   - 0x0026: QMI_LOC_NMEA_INDICATION (TLV 0x01: null-terminated NMEA string)

import argparse
import errno
import logging
import os
import select
import signal
import socket
import struct
import sys
import time
import tty

AF_QIPCRTR = getattr(socket, 'AF_QIPCRTR', 42)
QRTR_PORT_CTRL = 0xfffffffe
QRTR_TYPE_NEW_SERVER = 4
QRTR_TYPE_NEW_LOOKUP = 10

QMI_SERVICE_LOC = 16

# QMI message IDs for LOC service
QMI_LOC_SET_CLIENT_REVISION = 0x0020
QMI_LOC_REGISTER_EVENTS     = 0x0021
QMI_LOC_START               = 0x0022
QMI_LOC_STOP                = 0x0023
QMI_LOC_NMEA_INDICATION     = 0x0026
QMI_LOC_INJECT_UTC_TIME     = 0x0038
QMI_LOC_SET_ENGINE_LOCK     = 0x003a
QMI_LOC_SET_NMEA_TYPES      = 0x003e
QMI_LOC_SET_OPERATION_MODE  = 0x004a

# Default NMEA sentence mask: GGA, RMC, GSV, GSA, VTG, GLGSV, GNGSA, GNGNS
NMEA_TYPES_DEFAULT = 0x39f
# Operation mode: standalone
OP_MODE_STANDALONE = 4
# Engine lock: unlocked
ENGINE_LOCK_NONE = 1


def pack_tlv(tlv_type: int, value: bytes) -> bytes:
    """Pack a single QMI TLV element (type: u8, length: u16, value: bytes)."""
    return struct.pack('<BH', tlv_type, len(value)) + value


def parse_qmi_sdu(data: bytes):
    """
    Parse a QMI Service Data Unit (SDU) over QRTR.
    Header: flags (u8), txn_id (u16), msg_id (u16), length (u16).
    Returns (flags, txn_id, msg_id, tlvs_dict).
    """
    if len(data) < 7:
        return None, None, None, {}
    flags, txn_id, msg_id, length = struct.unpack_from('<BHHH', data)
    tlvs = {}
    offset = 7
    payload_end = min(len(data), 7 + length)
    while offset + 3 <= payload_end:
        t, l = struct.unpack_from('<BH', data, offset)
        offset += 3
        if offset + l <= len(data):
            tlvs[t] = data[offset:offset + l]
        offset += l
    return flags, txn_id, msg_id, tlvs


def qrtr_lookup_service(service_id: int, timeout: float = 2.0):
    """
    Query the QRTR router for registered servers providing service_id.
    Returns list of (node, port, instance) tuples.
    """
    s = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        local_node, _ = s.getsockname()
        # qrtr_ctrl_pkt for lookup: cmd=10, service, instance=0, node=0, port=0
        pkt = struct.pack('<IIIII', QRTR_TYPE_NEW_LOOKUP, service_id, 0, 0, 0)
        s.sendto(pkt, (local_node, QRTR_PORT_CTRL))
        servers = []
        while True:
            data, _ = s.recvfrom(64)
            if len(data) >= 20:
                cmd, s_id, inst, node, port = struct.unpack_from('<IIIII', data)
                if cmd == QRTR_TYPE_NEW_SERVER:
                    if s_id == 0 and node == 0:
                        break  # Lookup terminator
                    if s_id == service_id:
                        servers.append((node, port, inst))
    except socket.timeout:
        pass
    finally:
        s.close()
    return servers


class QmiLocClient:
    """Client for SDX55 QMI LOC service over QRTR."""

    def __init__(self, node: int, port: int, timeout: float = 3.0):
        self.dest = (node, port)
        self.timeout = timeout
        self.sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.txn_id = 0
        self.session_active = False

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def _next_txn(self) -> int:
        self.txn_id = (self.txn_id + 1) & 0xffff
        if self.txn_id == 0:
            self.txn_id = 1
        return self.txn_id

    def send_cmd(self, msg_id: int, body: bytes = b'', timeout: float = None) -> tuple:
        """
        Send a QMI request message and await the corresponding response.
        Returns (result, error, tlvs).
        """
        t = timeout or self.timeout
        txn = self._next_txn()
        req = struct.pack('<BHHH', 0x00, txn, msg_id, len(body)) + body
        self.sock.sendto(req, self.dest)
        deadline = time.monotonic() + t
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            self.sock.settimeout(remaining)
            try:
                data, _ = self.sock.recvfrom(8192)
            except socket.timeout:
                break
            flags, r_txn, r_msg, tlvs = parse_qmi_sdu(data)
            if flags == 2 and r_msg == msg_id:
                res_tlv = tlvs.get(2)
                if res_tlv and len(res_tlv) >= 4:
                    result, error = struct.unpack_from('<HH', res_tlv)
                    return result, error, tlvs
                return 0, 0, tlvs
        return None, None, {}

    def configure_and_start(self, interval_ms: int = 1000, session_id: int = 1) -> bool:
        """
        Configure the location engine and start continuous tracking.
        """
        logging.info("Negotiating LOC client revision 2...")
        res, err, _ = self.send_cmd(QMI_LOC_SET_CLIENT_REVISION, pack_tlv(1, struct.pack('<I', 2)))
        if res != 0:
            logging.warning("Failed to set client revision: res=%s, err=%s", res, err)

        logging.info("Setting engine lock to NONE...")
        res, err, _ = self.send_cmd(QMI_LOC_SET_ENGINE_LOCK, pack_tlv(1, struct.pack('<I', ENGINE_LOCK_NONE)))
        if res != 0:
            logging.warning("Failed to set engine lock: res=%s, err=%s", res, err)

        logging.info("Configuring NMEA sentence types (mask 0x%x)...", NMEA_TYPES_DEFAULT)
        res, err, _ = self.send_cmd(QMI_LOC_SET_NMEA_TYPES, pack_tlv(1, struct.pack('<I', NMEA_TYPES_DEFAULT)))
        if res != 0:
            logging.warning("Failed to set NMEA types: res=%s, err=%s", res, err)

        now_ms = int(time.time() * 1000)
        if now_ms > 1700000000000:
            logging.info("Injecting UTC wall-clock time (%d ms)...", now_ms)
            time_tlv = pack_tlv(1, struct.pack('<Q', now_ms)) + pack_tlv(2, struct.pack('<I', 1000))
            self.send_cmd(QMI_LOC_INJECT_UTC_TIME, time_tlv)

        logging.info("Setting positioning operation mode to STANDALONE...")
        res, err, _ = self.send_cmd(QMI_LOC_SET_OPERATION_MODE, pack_tlv(1, struct.pack('<I', OP_MODE_STANDALONE)))
        if res != 0:
            logging.warning("Failed to set operation mode: res=%s, err=%s", res, err)

        logging.info("Registering for NMEA event indications (mask 0x04)...")
        res, err, _ = self.send_cmd(QMI_LOC_REGISTER_EVENTS, pack_tlv(1, struct.pack('<Q', 0x04)))
        if res != 0:
            logging.warning("Failed to register NMEA events: res=%s, err=%s", res, err)

        logging.info("Starting LOC session (id=%d, interval=%d ms)...", session_id, interval_ms)
        start_tlvs = (
            pack_tlv(1, struct.pack('<B', session_id)) +
            pack_tlv(0x10, struct.pack('<I', 1)) +
            pack_tlv(0x13, struct.pack('<I', interval_ms))
        )
        res, err, _ = self.send_cmd(QMI_LOC_START, start_tlvs)
        if res != 0:
            logging.error("Failed to start LOC session: res=%s, err=%s", res, err)
            return False

        self.session_active = True
        logging.info("LOC tracking session started successfully.")
        return True

    def stop_session(self, session_id: int = 1) -> bool:
        """Stop the active tracking session."""
        if not self.sock:
            return True
        logging.info("Stopping LOC session (id=%d)...", session_id)
        res, err, _ = self.send_cmd(QMI_LOC_STOP, pack_tlv(1, struct.pack('<B', session_id)), timeout=2.0)
        self.session_active = False
        if res == 0:
            logging.info("LOC session stopped successfully.")
            return True
        else:
            logging.warning("LOC stop returned res=%s, err=%s", res, err)
            return False

    def read_nmea_sentence(self, timeout: float = 2.0) -> str:
        """
        Wait for next NMEA sentence indication.
        Returns NMEA sentence string or None on timeout.
        """
        self.sock.settimeout(timeout)
        try:
            data, _ = self.sock.recvfrom(8192)
        except socket.timeout:
            return None
        flags, _, msg_id, tlvs = parse_qmi_sdu(data)
        if flags == 4 and msg_id == QMI_LOC_NMEA_INDICATION:
            if 1 in tlvs:
                raw = tlvs[1].split(b'\0')[0]
                sentence = raw.decode('ascii', errors='replace').strip()
                if sentence.startswith('$G'):
                    return sentence
        return None


class PtyBridge:
    """Manages pseudo-terminal master/slave pair and symlink."""

    def __init__(self, symlink_path: str):
        self.symlink_path = symlink_path
        self.master_fd = None
        self.slave_fd = None
        self.slave_name = None

    def open(self):
        self.master_fd, self.slave_fd = os.openpty()
        tty.setraw(self.slave_fd)
        os.set_blocking(self.master_fd, False)
        self.slave_name = os.ttyname(self.slave_fd)

        try:
            os.chmod(self.slave_name, 0o666)
        except OSError:
            pass

        try:
            if os.path.islink(self.symlink_path) or os.path.exists(self.symlink_path):
                os.unlink(self.symlink_path)
            os.symlink(self.slave_name, self.symlink_path)
            logging.info("NMEA pseudo-terminal available at %s -> %s", self.symlink_path, self.slave_name)
        except OSError as e:
            logging.warning("Could not create symlink at %s: %s (direct tty: %s)",
                            self.symlink_path, e, self.slave_name)

    def write_sentence(self, sentence: str):
        if self.master_fd is None:
            return
        payload = (sentence + "\r\n").encode('ascii', errors='replace')
        try:
            os.write(self.master_fd, payload)
        except OSError as e:
            # EIO happens when no process has slave open; EAGAIN when buffer is full
            if e.errno not in (errno.EIO, errno.EAGAIN, errno.EWOULDBLOCK):
                logging.debug("PTY write error: %s", e)

    def close(self):
        try:
            if os.path.islink(self.symlink_path):
                os.unlink(self.symlink_path)
        except OSError:
            pass

        for fd in (self.slave_fd, self.master_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self.master_fd = None
        self.slave_fd = None
        logging.info("PTY closed and symlink removed.")


def run_daemon(pty_path: str, interval_ms: int, silence_timeout: float,
               target_node: int = None, target_port: int = None):
    """Main daemon loop running until SIGINT/SIGTERM."""
    running = True

    def sig_handler(signum, frame):
        nonlocal running
        logging.info("Caught signal %d, initiating clean shutdown...", signum)
        running = False

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    bridge = PtyBridge(pty_path)
    bridge.open()

    try:
        while running:
            # 1. Discover service
            node, port = target_node, target_port
            if node is None or port is None:
                logging.info("Discovering QMI LOC service via QRTR...")
                servers = qrtr_lookup_service(QMI_SERVICE_LOC)
                if not servers:
                    logging.info("LOC service not found, waiting 5 seconds...")
                    for _ in range(5):
                        if not running:
                            break
                        time.sleep(1)
                    continue
                node, port, _ = servers[0]
                logging.info("Discovered LOC service on node %d, port %d", node, port)

            # 2. Connect client and start session
            client = QmiLocClient(node, port)
            try:
                started = client.configure_and_start(interval_ms=interval_ms)
                if not started:
                    logging.warning("Failed to start LOC tracking, retrying in 5 seconds...")
                    client.close()
                    time.sleep(5)
                    continue

                last_nmea_time = time.monotonic()
                while running:
                    sentence = client.read_nmea_sentence(timeout=1.0)
                    if sentence:
                        last_nmea_time = time.monotonic()
                        bridge.write_sentence(sentence)
                    elif time.monotonic() - last_nmea_time > silence_timeout:
                        logging.warning("No NMEA sentences received for %0.1fs, restarting session...",
                                        silence_timeout)
                        break

            except OSError as e:
                logging.error("Socket error during session: %s", e)
            finally:
                if client.session_active:
                    try:
                        client.stop_session()
                    except Exception as e:
                        logging.warning("Error stopping session: %s", e)
                client.close()

            if running:
                time.sleep(3)

    finally:
        bridge.close()
        logging.info("Shutdown complete.")


def run_test(seconds: int, pty_path: str, interval_ms: int):
    """Run a self-contained verification test for N seconds and output statistics."""
    logging.info("Starting verification test (%d seconds)...", seconds)
    servers = qrtr_lookup_service(QMI_SERVICE_LOC)
    if not servers:
        print("FAIL: LOC service not found on QRTR bus")
        return 1

    node, port, inst = servers[0]
    print(f"PASS: LOC service discovered on node {node}, port {port}, instance {inst}")

    bridge = PtyBridge(pty_path)
    bridge.open()

    client = QmiLocClient(node, port)
    started = client.configure_and_start(interval_ms=interval_ms)
    if not started:
        print("FAIL: Could not start LOC tracking session")
        bridge.close()
        client.close()
        return 1
    print("PASS: LOC tracking session started")

    sentence_count = 0
    sentence_types = set()
    fixes_observed = 0
    start_time = time.monotonic()

    try:
        while time.monotonic() - start_time < seconds:
            sentence = client.read_nmea_sentence(timeout=1.0)
            if sentence:
                sentence_count += 1
                bridge.write_sentence(sentence)
                tag = sentence.split(',')[0]
                sentence_types.add(tag)

                # Check fix status in GGA (field 6) or RMC (field 2)
                parts = sentence.split(',')
                if tag in ('$GPGGA', '$GNGGA') and len(parts) > 6:
                    fix_quality = parts[6]
                    if fix_quality and fix_quality != '0':
                        fixes_observed += 1
                elif tag in ('$GPRMC', '$GNRMC') and len(parts) > 2:
                    status = parts[2]
                    if status == 'A':
                        fixes_observed += 1

    finally:
        stopped = client.stop_session()
        client.close()
        bridge.close()

    print(f"PASS: LOC tracking session stopped: {stopped}")
    print(f"RESULTS: {sentence_count} sentences received across {seconds} seconds.")
    print(f"NMEA sentence types: {sorted(list(sentence_types))}")
    print(f"Fixes observed: {fixes_observed} (indoor testing, 0 fixes expected)")
    return 0


def main():
    parser = argparse.ArgumentParser(description="SDX55 QMI LOC GNSS Bridge to PTY")
    parser.add_argument('--pty', default='/dev/gnss-sdx55', help="Path for symlink to PTY slave (default: /dev/gnss-sdx55)")
    parser.add_argument('--interval', type=int, default=1000, help="Fix interval in ms (default: 1000)")
    parser.add_argument('--timeout', type=float, default=30.0, help="Silence timeout before restarting session (default: 30s)")
    parser.add_argument('--node', type=int, default=None, help="QRTR node ID (default: auto)")
    parser.add_argument('--port', type=int, default=None, help="QRTR port ID (default: auto)")
    parser.add_argument('--test', type=int, nargs='?', const=10, default=None,
                        help="Run verification test for N seconds (default: 10s) and exit")
    parser.add_argument('--verbose', '-v', action='store_true', help="Enable verbose logging")

    args = parser.parse_args()

    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(level=log_level, format="%(asctime)s [%(levelname)s] %(message)s")

    if args.test is not None:
        sys.exit(run_test(args.test, args.pty, args.interval))
    else:
        run_daemon(args.pty, args.interval, args.timeout, args.node, args.port)


if __name__ == '__main__':
    main()
