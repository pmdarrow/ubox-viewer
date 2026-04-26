/// AVFrame header parser for UBIA video stream.
///
/// Wire format is 16 bytes (little-endian):
///   codec_id(2) flags(1) cam_index(1) onlineNum(1) recordstatus(1)
///   temperature(2) varbit(1) playSeq(1) resolution(1) framerate(1)
///   timestamp(4)
///
/// The Java app defines FRAMEINFO_SIZE=24 (adding videoWidth(4) + videoHeight(4)),
/// but those fields are NOT transmitted on the wire — they're populated from the
/// SPS NAL unit after decoding.
import Foundation

public struct AVFrame {
    public let codecID: UInt16
    public let flags: UInt8
    public let camIndex: UInt8
    public let onlineNum: UInt8
    public let recordStatus: UInt8
    public let temperature: Int16
    public let varbit: UInt8
    public let playSeq: UInt8
    public let resolution: UInt8
    public let framerate: UInt8
    public let timestamp: UInt32
    public let data: Data

    public var isIFrame: Bool { (flags & 0x01) != 0 }

    public var activeViewers: Int {
        Int(onlineNum & 0x0f)
    }

    public var batteryPercent: Int? {
        guard hasBatteryStatus else { return nil }
        return Int(statusWord & 0x007f)
    }

    public var isCharging: Bool? {
        guard hasBatteryStatus else { return nil }
        return (statusWord & 0x0100) == 0x0100
    }

    public var cellularSignalBars: Int? {
        // UBIA embeds cellular signal in vendor SEI payloads. H.264 and H.265
        // place the same status marker at slightly different offsets.
        if payloadByte(at: 4) == 0x06,
           payloadByte(at: 5) == 0xf0,
           let rawSignal = payloadByte(at: 16) {
            return Self.cellularSignalBars(from: rawSignal)
        }

        if payloadByte(at: 4) == 0x4e,
           payloadByte(at: 6) == 0xf0,
           let rawSignal = payloadByte(at: 17) {
            return Self.cellularSignalBars(from: rawSignal)
        }

        return nil
    }

    public var isVideo: Bool {
        [P4P.codecVideoH264, P4P.codecVideoH265,
         P4P.codecVideoMPEG4, P4P.codecVideoMJPEG].contains(codecID)
    }

    public var codecName: String {
        switch codecID {
        case P4P.codecVideoH264:  return "H.264"
        case P4P.codecVideoH265:  return "H.265"
        case P4P.codecVideoMPEG4: return "MPEG4"
        case P4P.codecVideoMJPEG: return "MJPEG"
        case P4P.codecAudioG726:  return "G.726"
        default:                  return "unknown(\(codecID))"
        }
    }

    /// Parse a 16-byte AVFrame wire header and attach the frame payload.
    static func parse(header: Data, data: Data = Data()) -> AVFrame {
        precondition(header.count >= 16, "AVFrame header too short: \(header.count)")
        let s = header.startIndex
        return AVFrame(
            codecID: header.uint16LE(at: 0),
            flags: header[s + 2],
            camIndex: header[s + 3],
            onlineNum: header[s + 4],
            recordStatus: header[s + 5],
            temperature: header.int16LE(at: 6),
            varbit: header[s + 8],
            playSeq: header[s + 9],
            resolution: header[s + 10],
            framerate: header[s + 11],
            timestamp: header.uint32LE(at: 12),
            data: data
        )
    }

    private var hasBatteryStatus: Bool {
        (varbit & 0x80) == 0x80
    }

    private var statusWord: UInt16 {
        UInt16(bitPattern: temperature)
    }

    private func payloadByte(at offset: Int) -> UInt8? {
        guard data.count > offset else { return nil }
        return data[data.startIndex + offset]
    }

    private static func cellularSignalBars(from rawSignal: UInt8) -> Int? {
        switch rawSignal {
        case 1:
            return 1
        case 2:
            return 2
        case 3:
            return 3
        case 4:
            return 4
        case 5, 6:
            return 5
        default:
            return nil
        }
    }
}
