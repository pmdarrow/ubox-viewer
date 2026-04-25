/// Streaming RDT block parser for UBIA P4P video/audio data.
///
/// The KCP layer delivers a contiguous byte stream of RDT blocks. Each block:
///
///   [16-byte RDT header][16-byte AVFrame header][payload data]
///
/// RDT header layout:
///   type(1) + channel(3) + frag_offset(2) + seq(2) + payload_size(4) + crc(4)
///
/// The payload_size field gives the number of bytes following the RDT header,
/// which includes the AVFrame header (16 bytes) + the actual media data.
///
/// Block types:
///   - 0x11 = video (H.265 NAL units in Annex B format)
///   - 0x13 = audio (G.726 or other codec)
import Foundation

/// Streaming parser that buffers incoming data and yields parsed frames.
final class RDTParser {
    private var buffer: [UInt8] = []
    private let onVideo: ((Data, AVFrame) -> Void)?
    private let onAudio: ((Data, AVFrame) -> Void)?
    private(set) var videoFrames = 0
    private(set) var audioFrames = 0

    init(
        onVideo: ((Data, AVFrame) -> Void)? = nil,
        onAudio: ((Data, AVFrame) -> Void)? = nil
    ) {
        self.onVideo = onVideo
        self.onAudio = onAudio
    }

    /// Add incoming KCP payload data and parse any complete blocks.
    func feed(_ data: Data) {
        buffer.append(contentsOf: data)
        parseBlocks()
    }

    /// Discard buffered data (e.g. after skipping lost KCP packets).
    func reset() {
        buffer.removeAll()
    }

    // MARK: - Private

    private func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }

    private func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(buffer[offset]) |
        UInt32(buffer[offset + 1]) << 8 |
        UInt32(buffer[offset + 2]) << 16 |
        UInt32(buffer[offset + 3]) << 24
    }

    /// Consume as many complete RDT blocks as possible from the buffer.
    private func parseBlocks() {
        while true {
            guard buffer.count >= P4P.rdtHeaderSize else { break }

            let blockType = buffer[0]
            if blockType != P4P.rdtVideo && blockType != P4P.rdtAudio {
                var found = false
                for i in 1..<(buffer.count - 3) {
                    if (buffer[i] == P4P.rdtVideo || buffer[i] == P4P.rdtAudio)
                        && buffer[i + 1] == 0x00
                        && buffer[i + 2] == 0x00
                        && buffer[i + 3] == 0x01
                    {
                        Log.warning("Skipped \(i) bytes of unknown data")
                        buffer.removeFirst(i)
                        found = true
                        break
                    }
                }
                if !found { break }
                continue
            }

            let payloadSize = Int(readUInt32LE(at: 8))
            let totalBlock = P4P.rdtHeaderSize + payloadSize

            guard buffer.count >= totalBlock else { break }

            let seq = readUInt16LE(at: 6)

            if payloadSize < P4P.avframeWireSize {
                Log.warning(
                    "RDT block seq=\(seq) too small (payload=\(payloadSize))"
                )
                buffer.removeFirst(totalBlock)
                continue
            }

            let avfStart = P4P.rdtHeaderSize
            let avfEnd = avfStart + P4P.avframeWireSize
            let avfBytes = Data(buffer[avfStart..<avfEnd])
            let mediaData = Data(buffer[avfEnd..<totalBlock])

            let frame = AVFrame.parse(header: avfBytes, data: mediaData)

            if blockType == P4P.rdtVideo {
                videoFrames += 1
                if videoFrames <= 5 {
                    Log.info("RDT video frame #\(videoFrames): \(mediaData.count) bytes, I=\(frame.isIFrame), codec=\(frame.codecName)")
                }
                onVideo?(mediaData, frame)
            } else {
                audioFrames += 1
                onAudio?(mediaData, frame)
            }

            buffer.removeFirst(totalBlock)
        }
    }
}
