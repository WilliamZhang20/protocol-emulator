"""Independent reference models for line codes and CRCs.

These are written the conventional software way (byte-reflected CRC tables,
explicit stuffing/NRZI loops), not the way the fabric computes them, so a
match is real cross-checking rather than self-consistency.
"""

from __future__ import annotations

import zlib


def crc16_usb(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def ethernet_fcs(frame: bytes) -> bytes:
    return zlib.crc32(frame).to_bytes(4, "little")


def lsb_bits(data: bytes) -> list[int]:
    return [(byte >> i) & 1 for byte in data for i in range(8)]


def bits_to_bytes(bits: list[int]) -> bytes:
    assert len(bits) % 8 == 0, f"{len(bits)} bits is not a whole number of bytes"
    return bytes(sum(bits[i + j] << j for j in range(8)) for i in range(0, len(bits), 8))


# USB line states seen on (D+, D-) for low speed.
J, K, SE0 = "J", "K", "SE0"
USB_SYNC = 0x80


def usb_state(dp: int, dm: int) -> str:
    if dp == 0 and dm == 0:
        return SE0
    if dp == 0 and dm == 1:
        return J
    if dp == 1 and dm == 0:
        return K
    return "SE1"


def usb_encode(packet: bytes) -> list[str]:
    """SYNC..CRC bytes -> line states per bit, with stuffing, NRZI and EOP."""
    stuffed, ones = [], 0
    for bit in lsb_bits(packet):
        stuffed.append(bit)
        ones = ones + 1 if bit else 0
        if ones == 6:
            stuffed.append(0)
            ones = 0
    states, level = [], J
    for bit in stuffed:
        if bit == 0:
            level = K if level == J else J
        states.append(level)
    return states + [SE0, SE0, J]


def usb_decode(states: list[str]) -> tuple[bytes, int]:
    """Line states per bit -> (packet bytes, SE0 bit count). Asserts on
    stuffing violations."""
    bits, ones, previous, index = [], 0, J, 0
    while index < len(states) and states[index] != SE0:
        state = states[index]
        bit = 1 if state == previous else 0
        previous = state
        index += 1
        if ones == 6:
            assert bit == 0, "missing stuffed bit"
            ones = 0
            continue
        bits.append(bit)
        ones = ones + 1 if bit else 0
    se0 = 0
    while index < len(states) and states[index] == SE0:
        se0 += 1
        index += 1
    assert index < len(states) and states[index] == J, "EOP must end in J"
    return bits_to_bytes(bits), se0
