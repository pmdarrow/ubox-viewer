import Foundation

public extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) |
        UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) |
        UInt32(self[startIndex + offset + 1]) << 8 |
        UInt32(self[startIndex + offset + 2]) << 16 |
        UInt32(self[startIndex + offset + 3]) << 24
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }

    func uint16BE(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 |
        UInt16(self[startIndex + offset + 1])
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[startIndex + offset] = UInt8(value & 0xFF)
        self[startIndex + offset + 1] = UInt8(value >> 8)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[startIndex + offset] = UInt8(value & 0xFF)
        self[startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
        self[startIndex + offset + 2] = UInt8((value >> 16) & 0xFF)
        self[startIndex + offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func writeASCII(_ string: String, at offset: Int, maxLength: Int) {
        for (i, byte) in string.utf8.prefix(maxLength).enumerated() {
            self[startIndex + offset + i] = byte
        }
    }

    mutating func writeIPv4(_ ip: String, at offset: Int) {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        for (i, byte) in parts.prefix(4).enumerated() {
            self[startIndex + offset + i] = byte
        }
    }

    func ipString(at offset: Int) -> String {
        let s = startIndex + offset
        return "\(self[s]).\(self[s+1]).\(self[s+2]).\(self[s+3])"
    }

    func asciiString(at offset: Int, maxLength: Int) -> String {
        let start = startIndex + offset
        let end = Swift.min(start + maxLength, endIndex)
        let slice = self[start..<end]
        let trimmed = slice.prefix(while: { $0 != 0 })
        return String(bytes: trimmed, encoding: .ascii) ?? ""
    }
}
