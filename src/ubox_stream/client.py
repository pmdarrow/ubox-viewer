"""
UBIA P4P protocol client — connects to a camera via relay and receives video.

Connection flow:
  1. Send query to master servers (m1-m6.ubianet.com:10240)
  2. Parse response for VPG relay server list
  3. Send relay wakeup to VPG servers (:20001)
  4. Wait for wakeup response
  5. Send relay stream request
  6. Parse response for relay data endpoint IP:port
  7. Send knock to relay endpoint
  8. Exchange keepalives, start video via AV control
  9. Receive KCP video data, parse RDT blocks, output clean H.265
"""
import socket
import struct
import select
import time
import logging
import random
from typing import Callable

from ubox_stream import protocol
from ubox_stream import crypto
from ubox_stream.rdt import RDTParser
from ubox_stream import avframe

log = logging.getLogger(__name__)

MASTER_SERVERS = [
    ("m1.ubianet.com", 10240),
    ("m2.ubianet.com", 10240),
    ("m3.ubianet.com", 10240),
    ("m4.ubianet.com", 10240),
    ("m5.ubianet.com", 10240),
    ("m6.ubianet.com", 10240),
]

_resolved_masters: list[tuple[str, int]] = []


def _resolve_masters() -> list[tuple[str, int]]:
    global _resolved_masters
    if _resolved_masters:
        return _resolved_masters
    resolved = []
    for host, port in MASTER_SERVERS:
        try:
            ip = socket.gethostbyname(host)
            resolved.append((ip, port))
            log.info("Resolved %s -> %s", host, ip)
        except socket.gaierror:
            log.warning("Failed to resolve %s", host)
    _resolved_masters = resolved
    return resolved


class P4PClient:
    IDLE = 0
    QUERYING = 1
    WAKING_RELAY = 2
    STREAM_REQUESTED = 3
    KNOCKING = 4
    CONNECTED = 5

    def __init__(self, uid: str, password: str, username: str = "admin",
                 stream_type: int = protocol.STREAM_MAIN):
        self.uid = uid
        self.password = password
        self.username = username
        self.stream_type = stream_type
        self.state = self.IDLE
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        self.sock.bind(("", 0))
        self.local_port = self.sock.getsockname()[1]
        log.info("Bound UDP socket on port %d", self.local_port)

        self.relay_servers: list[tuple[str, int]] = []
        self.relay_endpoint: tuple[str, int] | None = None
        self.session_token = 0
        self.kcp_conv = 0

        self._kcp_recv_buf: dict[int, bytes] = {}
        self._kcp_next_sn = 0
        self._kcp_una = 0
        self._running = False

        self._video_file = None
        self._raw_dump_file = None
        self._bytes_written = 0
        self._rdt_parser: RDTParser | None = None
        self._video_callback: Callable[[bytes, avframe.AVFrame], None] | None = None

    def connect(self, timeout: float = 30.0) -> bool:
        """Run the full connection handshake. Returns True on success."""
        deadline = time.time() + timeout

        log.info("Phase 1: Querying master servers for relay info...")
        self.state = self.QUERYING
        query_pkt = protocol.build_query_request(self.uid)
        masters = _resolve_masters()
        if not masters:
            log.error("No master servers resolved")
            return False

        for master in masters:
            self.sock.sendto(query_pkt, master)
            log.debug("  Sent query to %s:%d", *master)

        if not self._wait_for_state(self.WAKING_RELAY, deadline):
            log.error("Timed out waiting for query response")
            return False

        log.info("Phase 2: Sending relay wakeup to %d servers...",
                 len(self.relay_servers))
        wakeup_pkt = protocol.build_relay_wakeup_request(self.uid)
        retry_interval = 0.5
        wakeup_start = time.time()

        while self.state == self.WAKING_RELAY and time.time() < deadline:
            for srv in self.relay_servers:
                self.sock.sendto(wakeup_pkt, srv)
            if self._wait_for_state(self.STREAM_REQUESTED,
                                    min(time.time() + retry_interval, deadline)):
                break
            elapsed = time.time() - wakeup_start
            if elapsed > 15:
                log.warning("Relay wakeup taking %.1fs, still trying...", elapsed)

        if self.state != self.STREAM_REQUESTED:
            log.error("Timed out waiting for relay wakeup response")
            return False

        log.info("Phase 3: Sending relay stream request...")
        self._random_id = random.getrandbits(32)
        stream_pkt = protocol.build_relay_stream_request(
            uid=self.uid,
            password=self.password,
            username=self.username,
            local_port=self.local_port,
            random_id=self._random_id,
            stream_type=self.stream_type,
        )
        retry_interval = 1.0
        attempts = 0

        while self.state == self.STREAM_REQUESTED and time.time() < deadline:
            for srv in self.relay_servers:
                self.sock.sendto(stream_pkt, srv)
            attempts += 1
            if self._wait_for_state(self.KNOCKING,
                                    min(time.time() + retry_interval, deadline)):
                break
            if attempts > 16:
                log.error("Too many stream request retries")
                return False

        if self.state != self.KNOCKING:
            log.error("Timed out waiting for relay stream response")
            return False

        log.info("Phase 4: Sending knock to relay %s:%d",
                 *self.relay_endpoint)
        knock_pkt = protocol.build_knock(
            uid=self.uid,
            password=self.password,
            username=self.username,
            session_token=self.session_token,
            kcp_conv=self.kcp_conv,
        )
        self.sock.sendto(knock_pkt, self.relay_endpoint)

        for _ in range(3):
            time.sleep(0.2)
            self.sock.sendto(knock_pkt, self.relay_endpoint)
            self._recv_and_dispatch(timeout=0.3)

        self.state = self.CONNECTED
        log.info("Connected! Relay endpoint: %s:%d", *self.relay_endpoint)
        return True

    def start_video(self, channel: int = 0):
        """Send AV control command to start video streaming."""
        if self.relay_endpoint is None:
            log.error("Not connected, cannot start video")
            return
        av_pkt = protocol.build_av_start_video(channel,
                                               stream_type=self.stream_type)
        self.sock.sendto(av_pkt, self.relay_endpoint)
        quality = {protocol.STREAM_MAIN: "HD", protocol.STREAM_SUB: "SD",
                   protocol.STREAM_LF_MAIN: "LF-HD",
                   protocol.STREAM_LF_SUB: "LF-SD"}.get(self.stream_type, "?")
        log.info("Sent start video command (channel %d, %s)", channel, quality)

    def recv_loop(self, output_file: str = "output.h265",
                  raw_dump: str | None = None,
                  duration: float = 30.0):
        """Main receive loop — collects video data and writes clean H.265."""
        self._running = True
        self._bytes_written = 0

        self._video_file = open(output_file, "wb")
        self._rdt_parser = RDTParser(
            on_video=self._on_video_frame,
        )

        if raw_dump:
            self._raw_dump_file = open(raw_dump, "wb")

        start = time.time()
        keepalive_interval = 5.0
        last_keepalive = time.time()
        last_status = time.time()

        log.info("Receiving video for %.0fs, writing to %s", duration,
                 output_file)

        try:
            while self._running and (time.time() - start) < duration:
                self._recv_and_dispatch(timeout=0.1)

                now = time.time()
                if now - last_keepalive > keepalive_interval:
                    alive_pkt = protocol.build_alive(self.session_token,
                                                     self.kcp_conv)
                    if self.relay_endpoint:
                        self.sock.sendto(alive_pkt, self.relay_endpoint)
                    last_keepalive = now

                if now - last_status > 5.0:
                    elapsed = now - start
                    vf = self._rdt_parser.video_frames if self._rdt_parser else 0
                    af = self._rdt_parser.audio_frames if self._rdt_parser else 0
                    log.info("  %.0fs elapsed, %d bytes H.265, "
                             "%d video frames, %d audio frames, "
                             "KCP sn=%d",
                             elapsed, self._bytes_written, vf, af,
                             self._kcp_next_sn)
                    last_status = now

        except KeyboardInterrupt:
            log.info("Interrupted by user")
        finally:
            self._running = False
            if self._video_file:
                self._video_file.close()
                self._video_file = None
            if self._raw_dump_file:
                self._raw_dump_file.close()
                self._raw_dump_file = None
            vf = self._rdt_parser.video_frames if self._rdt_parser else 0
            log.info("Done. %d video frames, %d bytes written to %s",
                     vf, self._bytes_written, output_file)

    def _on_video_frame(self, data: bytes, frame: avframe.AVFrame):
        """Called by the RDT parser for each video frame."""
        if self._video_file:
            self._video_file.write(data)
            self._video_file.flush()
            self._bytes_written += len(data)
        if self._video_callback:
            self._video_callback(data, frame)

    def _wait_for_state(self, target_state: int, deadline: float) -> bool:
        while self.state < target_state and time.time() < deadline:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            self._recv_and_dispatch(timeout=min(remaining, 0.5))
        return self.state >= target_state

    def _recv_and_dispatch(self, timeout: float = 0.5):
        ready, _, _ = select.select([self.sock], [], [], timeout)
        if not ready:
            return

        while True:
            try:
                data, addr = self.sock.recvfrom(4096)
            except BlockingIOError:
                break
            if len(data) < 4:
                continue
            self._handle_packet(data, addr)

    def _handle_packet(self, data: bytes, addr: tuple[str, int]):
        dec = protocol.decrypt_packet(data)
        magic = protocol.get_packet_magic(dec)
        if magic != protocol.MAGIC:
            log.debug("Non-P4P packet from %s (magic=0x%04x, %d bytes)",
                      addr, magic, len(dec))
            return

        cmd = protocol.get_packet_cmd(dec)

        if cmd == protocol.CMD_QUERY_RSP:
            self._handle_query_response(dec)
        elif cmd == protocol.CMD_RLY_WAKEUP_RSP:
            self._handle_wakeup_response(dec)
        elif cmd == protocol.CMD_RLY_STREAM_RSP:
            self._handle_stream_response(dec, addr)
        elif cmd == protocol.CMD_ALIVE:
            log.debug("Keepalive from %s:%d", *addr)
        elif cmd == protocol.CMD_KCP_DATA:
            self._handle_kcp_data(dec, addr)
        elif cmd == protocol.CMD_KNOCK:
            log.debug("Knock response from %s:%d", *addr)
        else:
            log.debug("Unknown cmd 0x%04x from %s:%d (%d bytes)",
                      cmd, addr[0], addr[1], len(dec))

    def _handle_query_response(self, dec: bytes):
        if self.state != self.QUERYING:
            return
        result = protocol.parse_query_response(
            crypto.encode(dec)
        )
        if not result:
            result = self._parse_query_direct(dec)
        if result and result["relay_servers"]:
            self.relay_servers = [
                s for s in result["relay_servers"]
                if s[0] != "0.0.0.0"
            ]
            log.info("Got %d relay servers from query response",
                     len(self.relay_servers))
            for ip, port in self.relay_servers:
                log.info("  Relay: %s:%d", ip, port)
            self.state = self.WAKING_RELAY

    def _parse_query_direct(self, dec: bytes) -> dict | None:
        if len(dec) < 88:
            return None
        uid = dec[20:40].rstrip(b"\x00").decode("ascii", errors="replace")
        relay_servers = []
        for i in range(4):
            offset = 72 + i * 4
            if offset + 4 <= len(dec):
                ip = socket.inet_ntoa(dec[offset:offset + 4])
                if ip != "0.0.0.0":
                    relay_servers.append((ip, 20001))
        return {"uid": uid, "relay_servers": relay_servers}

    def _handle_wakeup_response(self, dec: bytes):
        if self.state != self.WAKING_RELAY:
            return
        status = dec[16] if len(dec) > 16 else 0
        self._wakeup_responses_received = getattr(
            self, "_wakeup_responses_received", 0
        ) + 1
        log.debug("Relay wakeup response #%d, status=0x%02x",
                  self._wakeup_responses_received, status)
        if status >= 0x01 and self._wakeup_responses_received >= 2:
            log.info("Relay wakeup accepted after %d responses",
                     self._wakeup_responses_received)
            self.state = self.STREAM_REQUESTED

    def _handle_stream_response(self, dec: bytes, addr: tuple[str, int]):
        if self.state != self.STREAM_REQUESTED:
            return

        result = protocol.parse_relay_stream_response(dec)
        if not result:
            log.warning("Could not parse relay stream response")
            return

        relay_ip = result["relay_ip"]
        relay_port = result["relay_port"]

        if relay_ip and relay_ip != "0.0.0.0" and relay_port > 0:
            self.relay_endpoint = (relay_ip, relay_port)
            self.session_token = result.get("session_token", 0)
            self.kcp_conv = result.get("kcp_conv", 0)
            self.state = self.KNOCKING
            log.info("Relay stream response: endpoint %s:%d, "
                     "session=0x%08x, conv=0x%08x",
                     relay_ip, relay_port,
                     self.session_token, self.kcp_conv)
        else:
            log.warning("Could not extract relay endpoint from stream "
                        "response, using sender %s:%d", *addr)
            self.relay_endpoint = addr
            self.state = self.KNOCKING

    def _handle_kcp_data(self, dec: bytes, addr: tuple[str, int]):
        kcp_data = dec[16:]
        offset = 0
        pending_acks = []

        while offset < len(kcp_data):
            seg = protocol.parse_kcp_segment(kcp_data, offset)
            if seg is None:
                break

            if self.kcp_conv == 0:
                self.kcp_conv = seg["conv"]
                log.info("KCP conversation ID: 0x%08x", self.kcp_conv)

            if seg["cmd"] == protocol.KCP_CMD_PUSH:
                data_end = seg["data_offset"] + seg["len"]
                if data_end > len(kcp_data):
                    log.warning("KCP segment data truncated: need %d have %d",
                                data_end, len(kcp_data))
                    break

                payload = kcp_data[seg["data_offset"]:data_end]
                self._process_kcp_payload(seg["sn"], seg["frg"], payload)

                pending_acks.append(
                    protocol.build_kcp_ack(
                        seg["conv"], seg["sn"], seg["ts"], self._kcp_una
                    )
                )
                offset = data_end
            else:
                offset += protocol.KCP_HEADER_SIZE

        if pending_acks and self.relay_endpoint:
            self._send_batched_acks(pending_acks)

    def _send_batched_acks(self, acks: list[bytes]):
        total_kcp = b"".join(acks)
        pkt = bytearray(16 + len(total_kcp))
        struct.pack_into("<HH", pkt, 0, protocol.MAGIC, protocol.VERSION)
        struct.pack_into("<H", pkt, 4, len(total_kcp))
        struct.pack_into("<H", pkt, 8, protocol.CMD_KCP_ACK)
        struct.pack_into("<H", pkt, 10, 0x21)
        pkt[16:] = total_kcp
        encrypted = crypto.encode(bytes(pkt))
        self.sock.sendto(encrypted, self.relay_endpoint)

    def _process_kcp_payload(self, sn: int, frg: int, data: bytes):
        self._kcp_recv_buf[sn] = data
        self._kcp_una = max(self._kcp_una, sn + 1)

        while self._kcp_next_sn in self._kcp_recv_buf:
            chunk = self._kcp_recv_buf.pop(self._kcp_next_sn)
            self._kcp_next_sn += 1
            self._deliver_data(chunk)

    def _deliver_data(self, data: bytes):
        if self._raw_dump_file:
            self._raw_dump_file.write(data)
            self._raw_dump_file.flush()
        if self._rdt_parser:
            self._rdt_parser.feed(data)

    def close(self):
        self._running = False
        if self._video_file:
            self._video_file.close()
            self._video_file = None
        if self._raw_dump_file:
            self._raw_dump_file.close()
            self._raw_dump_file = None
        self.sock.close()
