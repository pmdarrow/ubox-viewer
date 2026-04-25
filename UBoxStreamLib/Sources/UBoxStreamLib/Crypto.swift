/// UBIA P4P cipher — block-level bit rotation, XOR, and byte permutation.
///
/// The XOR key is a 32-byte string from .rodata of libUBICAPIs29.so.
/// Operates on 16-byte blocks with two rounds of DWORD rotation
/// sandwiching an XOR + byte permutation step.
import Foundation

enum Crypto {
    private static let xorKey: [UInt8] = Array(
        "I believe 1 ^ill win the battle!".utf8
    )

    private static let swap16 = [11, 9, 8, 15, 13, 10, 12, 14, 2, 1, 5, 0, 6, 4, 7, 3]
    private static let swap8  = [7, 4, 3, 2, 1, 6, 5, 0]
    private static let swap4  = [2, 3, 0, 1]
    private static let swap2  = [1, 0]

    private static func ror32(_ val: UInt32, _ shift: Int) -> UInt32 {
        let s = UInt32(shift & 31)
        return (val >> s) | (val << (32 &- s))
    }

    private static func rol32(_ val: UInt32, _ shift: Int) -> UInt32 {
        let s = UInt32(shift & 31)
        return (val << s) | (val >> (32 &- s))
    }

    private static func applySwap(_ data: [UInt8]) -> [UInt8] {
        let perm: [Int]
        switch data.count {
        case 16: perm = swap16
        case 8:  perm = swap8
        case 4:  perm = swap4
        case 2:  perm = swap2
        default: return data
        }
        return (0..<data.count).map { data[perm[$0]] }
    }

    /// Rotate each 4-byte DWORD in a 16-byte block.
    private static func rotateBlock(
        _ block: [UInt8], shifts: [Int], right: Bool
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16)
        let rotate = right ? ror32 : rol32
        for i in 0..<4 {
            let off = i * 4
            let dword = UInt32(block[off]) |
                        UInt32(block[off + 1]) << 8 |
                        UInt32(block[off + 2]) << 16 |
                        UInt32(block[off + 3]) << 24
            let rotated = rotate(dword, shifts[i])
            result[off]     = UInt8(rotated & 0xFF)
            result[off + 1] = UInt8((rotated >> 8) & 0xFF)
            result[off + 2] = UInt8((rotated >> 16) & 0xFF)
            result[off + 3] = UInt8((rotated >> 24) & 0xFF)
        }
        return result
    }

    private static func xorBytes(
        _ a: [UInt8], _ key: [UInt8], count: Int
    ) -> [UInt8] {
        (0..<count).map { a[$0] ^ key[$0 % key.count] }
    }

    /// Apply P4P crypto encode to data (operates on 16-byte blocks).
    static func encode(_ data: Data) -> Data {
        let bytes = Array(data)
        var out = [UInt8](repeating: 0, count: bytes.count)
        var offset = 0
        var remaining = bytes.count

        while remaining >= 16 {
            let block = Array(bytes[offset..<offset + 16])
            let temp = rotateBlock(block, shifts: [1, 5, 9, 13], right: true)
            let xored = xorBytes(temp, xorKey, count: 16)
            let swapped = applySwap(xored)
            let result = rotateBlock(swapped, shifts: [3, 7, 11, 15], right: true)
            for i in 0..<16 { out[offset + i] = result[i] }
            offset += 16
            remaining -= 16
        }

        if remaining > 0 {
            let tail = Array(bytes[offset..<offset + remaining])
            let xored = xorBytes(tail, xorKey, count: remaining)
            let swapped = applySwap(xored)
            for i in 0..<remaining { out[offset + i] = swapped[i] }
        }

        return Data(out)
    }

    /// Apply P4P crypto decode to data (reverses encode).
    static func decode(_ data: Data) -> Data {
        let bytes = Array(data)
        var out = [UInt8](repeating: 0, count: bytes.count)
        var offset = 0
        var remaining = bytes.count

        while remaining >= 16 {
            let block = Array(bytes[offset..<offset + 16])
            let temp = rotateBlock(block, shifts: [3, 7, 11, 15], right: false)
            let swapped = applySwap(temp)
            let xored = xorBytes(swapped, xorKey, count: 16)
            let result = rotateBlock(xored, shifts: [1, 5, 9, 13], right: false)
            for i in 0..<16 { out[offset + i] = result[i] }
            offset += 16
            remaining -= 16
        }

        if remaining > 0 {
            let tail = Array(bytes[offset..<offset + remaining])
            let swapped = applySwap(tail)
            let xored = xorBytes(swapped, xorKey, count: remaining)
            for i in 0..<remaining { out[offset + i] = xored[i] }
        }

        return Data(out)
    }
}
