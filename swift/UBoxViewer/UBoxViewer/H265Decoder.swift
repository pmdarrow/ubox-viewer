/// Hardware-accelerated H.265 Annex B decoder using VTDecompressionSession.
///
/// Splits raw Annex B byte streams on start codes, extracts VPS/SPS/PPS to
/// build a format description, then decodes VCL NAL units into CVPixelBuffers.
/// Based on the approach from github.com/finnvoor/Transcoding.
import CoreMedia
import Foundation
import OSLog
import VideoToolbox

final class H265Decoder {
    static let startCode = Data([0x00, 0x00, 0x00, 0x01])
    private static let logger = Logger(subsystem: "UBoxViewer", category: "H265Decoder")

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    func decode(_ data: Data) {
        for nalu in data.nalus() {
            guard let firstByte = nalu.first else { continue }
            let nalType = (firstByte & 0x7E) >> 1

            switch nalType {
            case 32: vps = nalu
            case 33: sps = nalu
            case 34:
                pps = nalu
                rebuildFormatDescription()
            case 0...9, 16...21:
                decodeVCL(nalu)
            default:
                break
            }
        }
    }

    func reset() {
        vps = nil
        sps = nil
        pps = nil
        formatDescription = nil
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: - Private

    private func rebuildFormatDescription() {
        guard let vps, let sps, let pps else { return }
        do {
            let desc = try CMVideoFormatDescription(hevcParameterSets: [vps, sps, pps])
            formatDescription = desc
            createSession()
        } catch {
            Self.logger.error("Format description failed: \(error, privacy: .public)")
        }
    }

    private func createSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        guard let formatDescription else { return }

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            Self.logger.error("Decompression session creation failed: \(status)")
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    private func decodeVCL(_ nalu: Data) {
        guard let formatDescription, let session else { return }

        var avcc = withUnsafeBytes(of: UInt32(nalu.count).bigEndian) { Data($0) } + nalu

        avcc.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }

            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: baseAddress,
                blockLength: pointer.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: pointer.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr, let blockBuffer else { return }

            var sampleSize = pointer.count
            var sampleBuffer: CMSampleBuffer?
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else { return }

            var infoFlags = VTDecodeInfoFlags()
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._1xRealTimePlayback],
                infoFlagsOut: &infoFlags
            ) { [weak self] decodeStatus, _, imageBuffer, _, _ in
                guard decodeStatus == noErr, let imageBuffer else { return }
                self?.onDecodedFrame?(imageBuffer)
            }
        }
    }
}

// MARK: - Annex B NAL unit splitting

private extension Data {
    func nalus() -> [Data] {
        var units: [Data] = []
        var i = 0
        let bytes = [UInt8](self)
        let len = bytes.count

        while i <= len - 4 {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                let naluStart = i + 4
                var naluEnd = len
                var j = naluStart
                while j <= len - 4 {
                    if bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                        naluEnd = j
                        break
                    }
                    j += 1
                }
                if naluStart < naluEnd {
                    units.append(Data(bytes[naluStart..<naluEnd]))
                }
                i = naluEnd
            } else {
                i += 1
            }
        }

        return units
    }
}
