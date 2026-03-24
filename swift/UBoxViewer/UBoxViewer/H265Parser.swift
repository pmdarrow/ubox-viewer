/// Parses an H.265 Annex B byte stream into NAL units and produces
/// CMSampleBuffers suitable for AVSampleBufferDisplayLayer.
///
/// Accumulates VPS/SPS/PPS parameter sets, then wraps each VCL NAL
/// (IDR or trailing slice) into a CMSampleBuffer with a length-prefix
/// format (HVCC) instead of start codes.
import AVFoundation
import CoreMedia
import VideoToolbox

final class H265Parser {
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?

    /// Feed a chunk of raw H.265 Annex B data (may contain multiple NAL units).
    /// Returns an array of CMSampleBuffers ready for display.
    func parse(_ data: Data) -> [CMSampleBuffer] {
        let nalUnits = splitNALUnits(data)
        var samples: [CMSampleBuffer] = []

        for nal in nalUnits {
            guard nal.count >= 2 else { continue }
            let nalType = (nal[0] >> 1) & 0x3F

            switch nalType {
            case 32: vps = nal
            case 33: sps = nal
            case 34:
                pps = nal
                rebuildFormatDescription()
            case 0...9, 16...21:
                if let sample = makeSampleBuffer(from: nal) {
                    samples.append(sample)
                }
            default:
                break
            }
        }

        return samples
    }

    // MARK: - Private

    private func splitNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = Array(data)
        var i = 0

        while i < bytes.count - 3 {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                let start = i + 3
                var end = bytes.count
                var j = start + 1
                while j < bytes.count - 2 {
                    if bytes[j] == 0 && bytes[j+1] == 0 &&
                       (bytes[j+2] == 1 || (bytes[j+2] == 0 && j + 3 < bytes.count && bytes[j+3] == 1)) {
                        end = j
                        if bytes[j+2] == 0 { end = j }
                        break
                    }
                    j += 1
                }
                if start < end {
                    units.append(Data(bytes[start..<end]))
                }
                i = end
            } else if i < bytes.count - 3 && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                let start = i + 4
                var end = bytes.count
                var j = start + 1
                while j < bytes.count - 2 {
                    if bytes[j] == 0 && bytes[j+1] == 0 &&
                       (bytes[j+2] == 1 || (bytes[j+2] == 0 && j + 3 < bytes.count && bytes[j+3] == 1)) {
                        end = j
                        break
                    }
                    j += 1
                }
                if start < end {
                    units.append(Data(bytes[start..<end]))
                }
                i = end
            } else {
                i += 1
            }
        }

        return units
    }

    private func rebuildFormatDescription() {
        guard let vps, let sps, let pps else { return }

        let vpsArr = Array(vps)
        let spsArr = Array(sps)
        let ppsArr = Array(pps)

        var desc: CMVideoFormatDescription?

        vpsArr.withUnsafeBufferPointer { vpsBuf in
            spsArr.withUnsafeBufferPointer { spsBuf in
                ppsArr.withUnsafeBufferPointer { ppsBuf in
                    var ptrs: [UnsafePointer<UInt8>] = [
                        vpsBuf.baseAddress!, spsBuf.baseAddress!, ppsBuf.baseAddress!
                    ]
                    var sizes: [Int] = [vpsArr.count, spsArr.count, ppsArr.count]

                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &ptrs,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )

                    if status != noErr {
                        desc = nil
                    }
                }
            }
        }

        if let desc {
            formatDescription = desc
        }
    }

    private func makeSampleBuffer(from nalUnit: Data) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var lengthPrefixed = Data(count: 4 + nalUnit.count)
        let len = UInt32(nalUnit.count).bigEndian
        withUnsafeBytes(of: len) { lengthPrefixed.replaceSubrange(0..<4, with: $0) }
        lengthPrefixed.replaceSubrange(4..<4+nalUnit.count, with: nalUnit)

        var blockBuffer: CMBlockBuffer?
        let dataCount = lengthPrefixed.count
        var status = lengthPrefixed.withUnsafeMutableBytes { rawBuf in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = lengthPrefixed.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataCount
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataCount
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr else { return nil }

        if let sampleBuffer {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true
            ) as? [NSMutableDictionary]
            attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        return sampleBuffer
    }
}
