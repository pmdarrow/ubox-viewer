"""
Streaming RDT block parser for UBIA P4P video/audio data.

The KCP layer delivers a contiguous byte stream of RDT blocks. Each block:

  [16-byte RDT header][16-byte AVFrame header][payload data]

RDT header layout:
  type(1) + channel(3) + frag_offset(2) + seq(2) + payload_size(4) + crc(4)

The payload_size field gives the number of bytes following the RDT header,
which includes the AVFrame header (16 bytes) + the actual media data.

Block types:
  0x11 = video (H.265 NAL units in Annex B format)
  0x13 = audio (G.726 or other codec)
"""
import struct
import logging
from dataclasses import dataclass
from typing import Callable

from ubox_stream import avframe
from ubox_stream import protocol

log = logging.getLogger(__name__)


@dataclass
class RDTBlock:
    block_type: int   # 0x11=video, 0x13=audio
    seq: int
    frame: avframe.AVFrame


class RDTParser:
    """Streaming parser that buffers incoming data and yields parsed frames."""

    def __init__(self,
                 on_video: Callable[[bytes, avframe.AVFrame], None] | None = None,
                 on_audio: Callable[[bytes, avframe.AVFrame], None] | None = None):
        self._buf = bytearray()
        self._on_video = on_video
        self._on_audio = on_audio
        self._video_frames = 0
        self._audio_frames = 0

    @property
    def video_frames(self) -> int:
        return self._video_frames

    @property
    def audio_frames(self) -> int:
        return self._audio_frames

    def feed(self, data: bytes) -> None:
        """Add incoming KCP payload data and parse any complete blocks."""
        self._buf.extend(data)
        self._parse_blocks()

    def _parse_blocks(self) -> None:
        """Consume as many complete RDT blocks as possible from the buffer."""
        while True:
            if len(self._buf) < protocol.RDT_HEADER_SIZE:
                break

            block_type = self._buf[0]
            if block_type not in (protocol.RDT_VIDEO, protocol.RDT_AUDIO):
                found = False
                for i in range(1, len(self._buf) - 3):
                    if (self._buf[i] in (protocol.RDT_VIDEO, protocol.RDT_AUDIO)
                            and self._buf[i + 1:i + 4] == b"\x00\x00\x01"):
                        log.warning("Skipped %d bytes of unknown data", i)
                        del self._buf[:i]
                        found = True
                        break
                if not found:
                    break
                continue

            payload_size = struct.unpack_from("<I", self._buf, 8)[0]
            total_block = protocol.RDT_HEADER_SIZE + payload_size

            if len(self._buf) < total_block:
                break

            seq = struct.unpack_from("<H", self._buf, 6)[0]

            if payload_size < protocol.AVFRAME_WIRE_SIZE:
                log.warning("RDT block seq=%d too small (payload=%d)", seq, payload_size)
                del self._buf[:total_block]
                continue

            avf_start = protocol.RDT_HEADER_SIZE
            avf_bytes = bytes(self._buf[avf_start:avf_start + protocol.AVFRAME_WIRE_SIZE])
            media_data = bytes(
                self._buf[avf_start + protocol.AVFRAME_WIRE_SIZE:total_block]
            )

            frame = avframe.parse(avf_bytes, media_data)

            if block_type == protocol.RDT_VIDEO:
                self._video_frames += 1
                if self._on_video:
                    self._on_video(media_data, frame)
            else:
                self._audio_frames += 1
                if self._on_audio:
                    self._on_audio(media_data, frame)

            del self._buf[:total_block]
