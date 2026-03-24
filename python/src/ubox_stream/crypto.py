"""
UBIA P4P "encryption" — a block cipher using bit rotation, XOR, and byte permutation.

The XOR key is a 32-byte string hardcoded in .rodata of libUBICAPIs29.so.
The cipher operates on 16-byte blocks with two rounds of DWORD rotation
sandwiching an XOR + byte permutation step.
"""
import struct

_XOR_KEY = b"I believe 1 ^ill win the battle!"

_SWAP_16 = [11, 9, 8, 15, 13, 10, 12, 14, 2, 1, 5, 0, 6, 4, 7, 3]
_SWAP_8 = [7, 4, 3, 2, 1, 6, 5, 0]
_SWAP_4 = [2, 3, 0, 1]
_SWAP_2 = [1, 0]


def _ror32(val: int, shift: int) -> int:
    shift &= 31
    return ((val >> shift) | (val << (32 - shift))) & 0xFFFFFFFF


def _rol32(val: int, shift: int) -> int:
    shift &= 31
    return ((val << shift) | (val >> (32 - shift))) & 0xFFFFFFFF


def _apply_swap(data: bytes, size: int) -> bytes:
    if size == 16:
        perm = _SWAP_16
    elif size == 8:
        perm = _SWAP_8
    elif size == 4:
        perm = _SWAP_4
    elif size == 2:
        perm = _SWAP_2
    else:
        return bytes(data)
    return bytes(data[perm[i]] for i in range(size))


def _rotate_block(block: bytes, shifts: list[int], direction: str) -> bytes:
    """Rotate each 4-byte DWORD in a 16-byte block."""
    result = bytearray(16)
    rotate = _ror32 if direction == "right" else _rol32
    for i in range(4):
        dword = struct.unpack_from("<I", block, i * 4)[0]
        rotated = rotate(dword, shifts[i])
        struct.pack_into("<I", result, i * 4, rotated)
    return bytes(result)


def _xor_bytes(a: bytes, b: bytes, length: int) -> bytes:
    return bytes(a[i] ^ b[i % len(b)] for i in range(length))


def encode(data: bytes) -> bytes:
    """Apply P4P crypto encode to data (operates on 16-byte blocks)."""
    buf = bytearray(data)
    out = bytearray(len(data))
    offset = 0
    remaining = len(data)

    while remaining >= 16:
        block = bytes(buf[offset:offset + 16])
        temp = _rotate_block(block, [1, 5, 9, 13], "right")
        xored = _xor_bytes(temp, _XOR_KEY, 16)
        swapped = _apply_swap(xored, 16)
        result = _rotate_block(swapped, [3, 7, 11, 15], "right")
        out[offset:offset + 16] = result
        offset += 16
        remaining -= 16

    if remaining > 0:
        tail = bytes(buf[offset:offset + remaining])
        xored = _xor_bytes(tail, _XOR_KEY, remaining)
        out[offset:offset + remaining] = _apply_swap(xored, remaining)

    return bytes(out)


def decode(data: bytes) -> bytes:
    """Apply P4P crypto decode to data (reverses encode)."""
    buf = bytearray(data)
    out = bytearray(len(data))
    offset = 0
    remaining = len(data)

    while remaining >= 16:
        block = bytes(buf[offset:offset + 16])
        temp = _rotate_block(block, [3, 7, 11, 15], "left")
        swapped = _apply_swap(temp, 16)
        xored = _xor_bytes(swapped, _XOR_KEY, 16)
        result = _rotate_block(xored, [1, 5, 9, 13], "left")
        out[offset:offset + 16] = result
        offset += 16
        remaining -= 16

    if remaining > 0:
        tail = bytes(buf[offset:offset + remaining])
        swapped = _apply_swap(tail, remaining)
        out[offset:offset + remaining] = _xor_bytes(swapped, _XOR_KEY, remaining)

    return bytes(out)
