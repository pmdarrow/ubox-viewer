"""
AVFrame header parser for UBIA video stream.

Wire format is 16 bytes (little-endian):
  codec_id(2) flags(1) cam_index(1) onlineNum(1) recordstatus(1)
  temperature(2) varbit(1) playSeq(1) resolution(1) framerate(1)
  timestamp(4)

The Java app defines FRAMEINFO_SIZE=24 (adding videoWidth(4) + videoHeight(4)),
but those fields are NOT transmitted on the wire — they're populated from the
SPS NAL unit after decoding.
"""
import struct
from dataclasses import dataclass

FRAMEINFO_SIZE = 16

FLAG_IFRAME = 0x01


@dataclass
class AVFrame:
    codec_id: int
    flags: int
    cam_index: int
    online_num: int
    record_status: int
    temperature: int
    varbit: int
    play_seq: int
    resolution: int
    framerate: int
    timestamp: int
    data: bytes

    @property
    def is_iframe(self) -> bool:
        return (self.flags & FLAG_IFRAME) != 0

    @property
    def is_video(self) -> bool:
        from ubox_stream.protocol import (CODEC_VIDEO_H264, CODEC_VIDEO_H265,
                                          CODEC_VIDEO_MPEG4, CODEC_VIDEO_MJPEG)
        return self.codec_id in (CODEC_VIDEO_H264, CODEC_VIDEO_H265,
                                 CODEC_VIDEO_MPEG4, CODEC_VIDEO_MJPEG)

    @property
    def codec_name(self) -> str:
        from ubox_stream.protocol import (CODEC_VIDEO_H264, CODEC_VIDEO_H265,
                                          CODEC_VIDEO_MPEG4, CODEC_VIDEO_MJPEG,
                                          CODEC_AUDIO_G726)
        names = {
            CODEC_VIDEO_H264: "H.264",
            CODEC_VIDEO_H265: "H.265",
            CODEC_VIDEO_MPEG4: "MPEG4",
            CODEC_VIDEO_MJPEG: "MJPEG",
            CODEC_AUDIO_G726: "G.726",
        }
        return names.get(self.codec_id, f"unknown({self.codec_id})")


def parse(header: bytes, frame_data: bytes = b"") -> AVFrame:
    """Parse a 16-byte AVFrame wire header and attach the frame payload."""
    if len(header) < FRAMEINFO_SIZE:
        raise ValueError(f"Header too short: {len(header)} < {FRAMEINFO_SIZE}")

    codec_id = struct.unpack_from("<H", header, 0)[0]
    flags = header[2]
    cam_index = header[3]
    online_num = header[4]
    record_status = header[5]
    temperature = struct.unpack_from("<h", header, 6)[0]
    varbit = header[8]
    play_seq = header[9]
    resolution = header[10]
    framerate = header[11]
    timestamp = struct.unpack_from("<I", header, 12)[0]

    return AVFrame(
        codec_id=codec_id,
        flags=flags,
        cam_index=cam_index,
        online_num=online_num,
        record_status=record_status,
        temperature=temperature,
        varbit=varbit,
        play_seq=play_seq,
        resolution=resolution,
        framerate=framerate,
        timestamp=timestamp,
        data=frame_data,
    )
