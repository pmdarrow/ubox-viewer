"""
UBIA P4P protocol packet builders and parsers.

Packet header (16 bytes):
  magic(2) + version(2) + payload_len(2) + reserved(2) + cmd(2) + sub(2) + flags(4)
"""
import struct
import socket

from ubox_stream import crypto

MAGIC = 0x1807
VERSION = 0x0010

CMD_QUERY_REQ = 0x1051
CMD_QUERY_RSP = 0x1052
CMD_RLY_WAKEUP_REQ = 0x1201
CMD_RLY_WAKEUP_RSP = 0x1202
CMD_RLY_STREAM_REQ = 0x1205
CMD_RLY_STREAM_RSP = 0x1206
CMD_LAN_SEARCH_REQ = 0x1301
CMD_LAN_SEARCH_RSP = 0x1304
CMD_KNOCK = 0x1403
CMD_KNOCK_RELAY = 0x130b
CMD_ALIVE = 0x1406
CMD_AV_CTRL = 0x1407
CMD_KCP_ACK = 0x1409
CMD_KCP_DATA = 0x140a

AV_CMD_START_VIDEO = 0x09

STREAM_SUB = 0       # SD — camera's sub stream (lower resolution)
STREAM_MAIN = 1      # HD — camera's main stream (full resolution)
STREAM_LF_SUB = 2    # Low-framerate SD (used for multi-cam grid views)
STREAM_LF_MAIN = 3   # Low-framerate HD

CODEC_VIDEO_MPEG4 = 76
CODEC_VIDEO_H263 = 77
CODEC_VIDEO_H264 = 78
CODEC_VIDEO_MJPEG = 79
CODEC_VIDEO_H265 = 80
CODEC_AUDIO_ADPCM = 139
CODEC_AUDIO_PCM = 140
CODEC_AUDIO_SPEEX = 141
CODEC_AUDIO_MP3 = 142
CODEC_AUDIO_G726 = 143

RDT_VIDEO = 0x11
RDT_AUDIO = 0x13

RDT_HEADER_SIZE = 16
AVFRAME_WIRE_SIZE = 16


def build_query_request(uid: str) -> bytes:
    """Build a 60-byte query request packet (encrypted)."""
    pkt = bytearray(60)
    struct.pack_into("<HH", pkt, 0, MAGIC, VERSION)
    struct.pack_into("<H", pkt, 4, 0x2C)
    struct.pack_into("<H", pkt, 8, CMD_QUERY_REQ)
    struct.pack_into("<H", pkt, 10, 0x28)
    uid_bytes = uid.encode("ascii")[:20].ljust(20, b"\x00")
    pkt[20:40] = uid_bytes
    return crypto.encode(bytes(pkt))


def parse_query_response(data: bytes) -> dict:
    """Parse a decrypted query response to extract relay server list."""
    dec = crypto.decode(data)
    magic = struct.unpack_from("<H", dec, 0)[0]
    if magic != MAGIC:
        return None
    cmd = struct.unpack_from("<H", dec, 8)[0]
    if cmd != CMD_QUERY_RSP:
        return None

    uid = dec[20:40].rstrip(b"\x00").decode("ascii", errors="replace")

    relay_servers = []
    for i in range(4):
        offset = 72 + i * 4
        if offset + 4 <= len(dec):
            ip = socket.inet_ntoa(dec[offset:offset + 4])
            relay_servers.append((ip, 20001))

    vpg_id = dec[40:44] if len(dec) > 43 else b""

    return {
        "uid": uid,
        "relay_servers": relay_servers,
        "vpg_id": vpg_id,
        "raw": dec,
    }


def build_relay_wakeup_request(uid: str) -> bytes:
    """Build a 60-byte relay wakeup request (encrypted)."""
    pkt = bytearray(60)
    struct.pack_into("<HH", pkt, 0, MAGIC, VERSION)
    struct.pack_into("<H", pkt, 4, 0x2C)
    struct.pack_into("<H", pkt, 8, CMD_RLY_WAKEUP_REQ)
    struct.pack_into("<H", pkt, 10, 0x24)
    pkt[16] = 0x01
    pkt[17] = 0x01
    uid_bytes = uid.encode("ascii")[:20].ljust(20, b"\x00")
    pkt[20:40] = uid_bytes
    return crypto.encode(bytes(pkt))


def parse_relay_wakeup_response(data: bytes) -> dict:
    """Parse a relay wakeup response."""
    dec = crypto.decode(data)
    magic = struct.unpack_from("<H", dec, 0)[0]
    if magic != MAGIC:
        return None
    cmd = struct.unpack_from("<H", dec, 8)[0]
    if cmd != CMD_RLY_WAKEUP_RSP:
        return None
    status = dec[16] if len(dec) > 16 else 0
    return {"cmd": cmd, "status": status, "raw": dec}


def build_relay_stream_request(
    uid: str, password: str, username: str = "admin",
    local_ip: str = "0.0.0.0", local_port: int = 0,
    random_id: int = 0, stream_type: int = STREAM_MAIN,
) -> bytes:
    """Build a relay stream request (124 bytes, encrypted).

    Layout:
      [0x00] header (16 bytes)
      [0x10] flags (4 bytes)
      [0x1c] local IP (4 bytes, network order)
      [0x20] local port (2 bytes LE)
      [0x28] UID (20 bytes)
      [0x3c] password (16 bytes)
      [0x58] random_id (4 bytes LE)
      [0x5c] username (16 bytes)
      [0x6c] subcommand (4 bytes): 0x09 0x00 0x01 0x01
    """
    pkt = bytearray(124)
    struct.pack_into("<HH", pkt, 0, MAGIC, VERSION)
    struct.pack_into("<H", pkt, 4, 0x6C)
    struct.pack_into("<H", pkt, 8, CMD_RLY_STREAM_REQ)
    struct.pack_into("<H", pkt, 10, 0x24)
    pkt[16] = 0x01

    if local_ip != "0.0.0.0":
        pkt[0x1c:0x20] = socket.inet_aton(local_ip)
    struct.pack_into("<H", pkt, 0x20, local_port)

    uid_bytes = uid.encode("ascii")[:20].ljust(20, b"\x00")
    pkt[0x28:0x3c] = uid_bytes

    pwd_bytes = password.encode("ascii")[:16].ljust(16, b"\x00")
    pkt[0x3c:0x4c] = pwd_bytes

    if random_id:
        struct.pack_into("<I", pkt, 0x58, random_id)

    user_bytes = username.encode("ascii")[:16].ljust(16, b"\x00")
    pkt[0x5c:0x6c] = user_bytes

    pkt[0x6c] = AV_CMD_START_VIDEO
    pkt[0x6e] = stream_type
    pkt[0x6f] = 0x01

    return crypto.encode(bytes(pkt))


def parse_relay_stream_response(dec: bytes) -> dict:
    """Parse a decrypted relay stream response.

    Layout:
      [0x14] client source port (2 bytes BE)
      [0x16] relay port (2 bytes BE)
      [0x18] relay IP (4 bytes, network order)
      [0x48] session token (4 bytes LE)
      [0x4c] KCP conv (4 bytes LE)
    """
    magic = struct.unpack_from("<H", dec, 0)[0]
    if magic != MAGIC:
        return None
    cmd = struct.unpack_from("<H", dec, 8)[0]
    if cmd != CMD_RLY_STREAM_RSP:
        return None

    relay_port = struct.unpack_from(">H", dec, 0x16)[0]
    relay_ip = socket.inet_ntoa(dec[0x18:0x1c])

    session_token = 0
    kcp_conv = 0
    if len(dec) > 0x4f:
        session_token = struct.unpack_from("<I", dec, 0x48)[0]
        kcp_conv = struct.unpack_from("<I", dec, 0x4c)[0]

    return {
        "cmd": cmd,
        "relay_ip": relay_ip,
        "relay_port": relay_port,
        "session_token": session_token,
        "kcp_conv": kcp_conv,
        "raw": dec,
    }


def build_knock(
    uid: str, password: str, username: str = "admin",
    session_token: int = 0, kcp_conv: int = 0,
) -> bytes:
    """Build a knock packet for the relay data endpoint (84 bytes).

    Layout:
      [0x10] UID (20 bytes)
      [0x24] password (16 bytes)
      [0x38] session_token (4 bytes LE)
      [0x3c] kcp_conv (4 bytes LE)
      [0x40] username (16 bytes)
    """
    pkt = bytearray(84)
    struct.pack_into("<HH", pkt, 0, MAGIC, VERSION)
    struct.pack_into("<H", pkt, 4, 0x44)
    struct.pack_into("<H", pkt, 8, CMD_KNOCK_RELAY)
    struct.pack_into("<H", pkt, 10, 0x21)

    uid_bytes = uid.encode("ascii")[:20].ljust(20, b"\x00")
    pkt[0x10:0x24] = uid_bytes

    pwd_bytes = password.encode("ascii")[:16].ljust(16, b"\x00")
    pkt[0x24:0x34] = pwd_bytes

    struct.pack_into("<I", pkt, 0x3c, session_token)
    struct.pack_into("<I", pkt, 0x40, kcp_conv)

    user_bytes = username.encode("ascii")[:16].ljust(16, b"\x00")
    pkt[0x44:0x54] = user_bytes

    return crypto.encode(bytes(pkt))


def build_alive(session_token: int = 0, conv: int = 0) -> bytes:
    """Build a keepalive packet."""
    pkt = bytearray(36)
    struct.pack_into("<HH", pkt, 0, MAGIC, VERSION)
    struct.pack_into("<H", pkt, 4, 0x14)
    struct.pack_into("<H", pkt, 8, CMD_ALIVE)
    struct.pack_into("<H", pkt, 10, 0x12)
    if conv:
        struct.pack_into("<I", pkt, 24, conv)
    return crypto.encode(bytes(pkt))


def build_av_start_video(channel: int = 0,
                         stream_type: int = STREAM_MAIN) -> bytes:
    """Build AV control command to start video streaming.

    Payload layout:
      byte 0: AV_CMD_START_VIDEO (0x09)
      byte 1: channel
      byte 2: stream_type (0=SD, 1=HD, 2=LF_SD, 3=LF_HD)
      byte 3: codec (1 = H.265)
    """
    pkt = bytearray(48)
    struct.pack_into("<HH", pkt, 0, MAGIC, VERSION)
    struct.pack_into("<H", pkt, 4, 0x20)
    struct.pack_into("<H", pkt, 8, CMD_AV_CTRL)
    pkt[16] = AV_CMD_START_VIDEO
    pkt[17] = channel & 0xFF
    pkt[18] = stream_type
    pkt[19] = 0x01
    return crypto.encode(bytes(pkt))


def decrypt_packet(data: bytes) -> bytes:
    """Decrypt an incoming P4P packet."""
    return crypto.decode(data)


def get_packet_cmd(dec: bytes) -> int:
    """Get the command code from a decrypted packet."""
    if len(dec) < 10:
        return 0
    return struct.unpack_from("<H", dec, 8)[0]


def get_packet_magic(dec: bytes) -> int:
    """Get the magic from a decrypted packet."""
    if len(dec) < 2:
        return 0
    return struct.unpack_from("<H", dec, 0)[0]


KCP_HEADER_SIZE = 24
KCP_CMD_PUSH = 81
KCP_CMD_ACK = 82
KCP_CMD_WASK = 83
KCP_CMD_WINS = 84


def parse_kcp_segment(data: bytes, offset: int = 0) -> dict:
    """Parse a KCP segment header (24 bytes) from data at the given offset."""
    if len(data) - offset < KCP_HEADER_SIZE:
        return None
    conv, cmd, frg, wnd, ts, sn, una, length = struct.unpack_from(
        "<IBBHIIII", data, offset
    )
    return {
        "conv": conv,
        "cmd": cmd,
        "frg": frg,
        "wnd": wnd,
        "ts": ts,
        "sn": sn,
        "una": una,
        "len": length,
        "data_offset": offset + KCP_HEADER_SIZE,
    }


def build_kcp_ack(conv: int, sn: int, ts: int, una: int, wnd: int = 256) -> bytes:
    """Build a KCP ACK segment."""
    return struct.pack("<IBBHIIII", conv, KCP_CMD_ACK, 0, wnd, ts, sn, una, 0)
