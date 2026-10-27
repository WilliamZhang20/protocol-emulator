"""Independent packet-level USB transaction oracle, NOT a PX8 implementation.

USB 2.0 sections 8.3, 8.5.3 and 8.6. One configured control endpoint, max
packet size 8. Framing/NRZI/stuffing and turnaround timing are separate pin-level
contracts. Packets here start with PID (SYNC and EOP are handled by the PHY).
The oracle has explicit packet buffers; mapping them to the fixed fabric remains
implementation work. No enumeration, descriptors, or class requests are modeled.
"""

from collections import deque

OUT, IN, SETUP = 0xE1, 0x69, 0x2D
DATA0, DATA1 = 0xC3, 0x4B
ACK, NAK, STALL = 0xD2, 0x5A, 0x1E


def crc5(value: int) -> int:
    """CRC of the 11 address/endpoint bits, returned in wire LSB-first order."""
    crc = 0x1F
    for bit in range(11):
        feedback = (crc ^ (value >> bit)) & 1
        crc = (crc >> 1) ^ (0x14 if feedback else 0)
    return crc ^ 0x1F


def crc16(payload: bytes) -> int:
    crc = 0xFFFF
    for byte in payload:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xA001 if crc & 1 else 0)
    return crc ^ 0xFFFF


def token(pid: int, address: int, endpoint: int) -> bytes:
    if pid not in (OUT, IN, SETUP) or not 0 <= address < 128 or not 0 <= endpoint < 16:
        raise ValueError("invalid token fields")
    value = address | endpoint << 7
    return bytes([pid]) + (value | crc5(value) << 11).to_bytes(2, "little")


def data_packet(pid: int, payload: bytes) -> bytes:
    if pid not in (DATA0, DATA1) or len(payload) > 8:
        raise ValueError("invalid low-speed data packet")
    return bytes([pid]) + payload + crc16(payload).to_bytes(2, "little")


class Device:
    """Transaction reference with one outstanding IN and one accepted OUT/SETUP."""

    def __init__(self, address: int = 0) -> None:
        if not 0 <= address < 128:
            raise ValueError("address must fit seven bits")
        self.address = address
        self.in_toggle = 0
        self.out_toggle = 0
        self.halted = False
        self.in_data: bytes | None = None
        self.received: deque[tuple[bool, bytes]] = deque()
        self.pending: int | None = None
        self.awaiting_ack = False

    def queue_in(self, payload: bytes) -> None:
        if len(payload) > 8 or self.in_data is not None:
            raise ValueError("IN packet too large or previous packet not ACKed")
        self.in_data = bytes(payload)

    def timeout(self) -> None:
        """Abort this exchange, retaining unacknowledged IN data for retry."""
        self.pending = None
        self.awaiting_ack = False

    def receive(self, packet: bytes, *, framing_valid: bool = True) -> bytes | None:
        pending, awaiting_ack = self.pending, self.awaiting_ack
        self.timeout()
        if not framing_valid or not packet or ((packet[0] & 15) ^ (packet[0] >> 4)) != 15:
            return None
        pid = packet[0]
        if pid == ACK:
            if len(packet) == 1 and awaiting_ack:
                self.in_data = None
                self.in_toggle ^= 1
            return None
        if pid in (IN, OUT, SETUP):
            if len(packet) != 3:
                return None
            field = int.from_bytes(packet[1:], "little")
            address, endpoint = field & 127, field >> 7 & 15
            if field >> 11 != crc5(field & 0x7FF) or address != self.address or endpoint != 0:
                return None
            if pid != IN:
                self.pending = pid
                return None
            if self.halted:
                return bytes([STALL])
            if self.in_data is None:
                return bytes([NAK])
            self.awaiting_ack = True
            return data_packet(DATA1 if self.in_toggle else DATA0, self.in_data)
        if pid not in (DATA0, DATA1) or pending not in (OUT, SETUP):
            return None
        if not 3 <= len(packet) <= 11:
            return None
        payload = packet[1:-2]
        if int.from_bytes(packet[-2:], "little") != crc16(payload):
            return None
        if pending == SETUP:
            if pid != DATA0 or len(payload) != 8:
                return None
            # A new SETUP supersedes the previous control transfer, even if
            # the application has not consumed its previous setup record.
            self.received.clear()
            self.received.append((True, payload))
            self.in_data = None
            self.halted = False
            self.in_toggle = self.out_toggle = 1
            return bytes([ACK])
        if self.halted:
            return bytes([STALL])
        if (pid == DATA1) != bool(self.out_toggle):
            return bytes([ACK])  # Retry after lost ACK: do not deliver twice.
        if self.received:
            return bytes([NAK])
        self.received.append((False, payload))
        self.out_toggle ^= 1
        return bytes([ACK])
