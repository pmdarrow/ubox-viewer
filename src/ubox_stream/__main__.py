#!/usr/bin/env python3
"""
UBIA P4P camera stream client.

Connects to a UBIA camera via relay servers and dumps a clean H.265
elementary stream (optionally remuxed to MP4).

Usage:
    ubox-stream --uid YOUR_CAMERA_UID --password YOUR_DEVICE_PASSWORD
    ubox-stream --uid ... --password ... --quality sd --duration 60
    ubox-stream --uid ... --password ... --mp4
"""
import argparse
import logging
import subprocess
import sys
import os

from ubox_stream import protocol
from ubox_stream.client import P4PClient


def main():
    parser = argparse.ArgumentParser(
        description="Connect to UBIA camera and dump video stream"
    )
    parser.add_argument(
        "--uid", required=True,
        help="Camera UID"
    )
    parser.add_argument(
        "--password", required=True,
        help="Device password from API"
    )
    parser.add_argument(
        "--username", default="admin",
        help="Device username (default: admin)"
    )
    parser.add_argument(
        "--quality", "-q", choices=["hd", "sd"], default="hd",
        help="Stream quality: hd (main stream) or sd (sub stream). "
             "Default: hd"
    )
    parser.add_argument(
        "--output", "-o", default=None,
        help="Output file path (default: output.h265, or output.mp4 with --mp4)"
    )
    parser.add_argument(
        "--mp4", action="store_true",
        help="Remux the output to MP4 after recording (requires ffmpeg)"
    )
    parser.add_argument(
        "--raw-dump", default=None,
        help="Also dump raw KCP data (with RDT headers) to this file for debugging"
    )
    parser.add_argument(
        "--duration", "-d", type=float, default=30.0,
        help="Recording duration in seconds (default: 30)"
    )
    parser.add_argument(
        "--timeout", "-t", type=float, default=30.0,
        help="Connection timeout in seconds (default: 30)"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Enable debug logging"
    )
    args = parser.parse_args()

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    stream_type = (protocol.STREAM_MAIN if args.quality == "hd"
                   else protocol.STREAM_SUB)

    h265_path = args.output
    if h265_path is None:
        h265_path = "output.h265"

    client = P4PClient(args.uid, args.password, args.username,
                       stream_type=stream_type)
    try:
        if not client.connect(timeout=args.timeout):
            logging.error("Failed to connect to camera %s", args.uid)
            sys.exit(1)

        client.start_video()
        client.recv_loop(
            output_file=h265_path,
            raw_dump=args.raw_dump,
            duration=args.duration,
        )
    except KeyboardInterrupt:
        logging.info("Interrupted")
    finally:
        client.close()

    if not os.path.exists(h265_path) or os.path.getsize(h265_path) == 0:
        logging.error("No video data received")
        sys.exit(1)

    if args.mp4:
        mp4_path = args.output if args.output and args.output.endswith(".mp4") \
            else h265_path.rsplit(".", 1)[0] + ".mp4"
        logging.info("Remuxing to %s ...", mp4_path)
        try:
            fps = str(client.reported_framerate or 15)
            subprocess.run([
                "ffmpeg", "-y",
                "-r", fps,
                "-f", "hevc", "-i", h265_path,
                "-c:v", "hevc_videotoolbox", "-q:v", "65",
                "-tag:v", "hvc1",
                "-movflags", "+faststart",
                mp4_path,
            ], check=True, capture_output=True)
            logging.info("MP4 written to %s", mp4_path)
        except FileNotFoundError:
            logging.error("ffmpeg not found — install it to use --mp4")
        except subprocess.CalledProcessError as e:
            logging.error("ffmpeg failed: %s", e.stderr.decode())

    logging.info("Done.")


if __name__ == "__main__":
    main()
