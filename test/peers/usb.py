"""A low-speed USB host on D+ and D-, `bit` cycles per bit.

Listening, it decodes each packet the chip sends (NRZI, bit stuffing) and
checks it as a referee: every transition lies on the bit grid of the
packet's first edge, SYNC is 0x80, a stuffed 0 follows every six 1s, a data
packet's CRC16 is right, and the packet ends with exactly two bits of SE0
and then J. `received` holds each packet's PID and data bytes (SYNC and CRC
removed). Only what the chip drives is heard, never the host's own packets.

Sending (`write`), each call is one packet, [PID, ...]: a token (OUT, IN,
SETUP, SOF) is [PID, address, endpoint] and gets its CRC5; a data packet
(DATA0, DATA1) [PID, data...] gets its CRC16; a handshake (ACK, NAK, STALL)
is the PID alone. The host drives J for `idle` bits, SYNC, the packet NRZI
coded and stuffed, two bits of SE0 and one of J. While neither side sends,
the host holds the bus at J (a real host's pull-downs and the device's D-
pull-up do; the pads here are pulled up), released at once when the chip
drives either line (decided at each falling clock edge, before the pads
update). The referee reads the chip's own drive. After a
packet that expects an answer (a data packet, or IN), with `timeout` set,
the chip's answer must start between 2 and `timeout` bit times after the
host's EOP (USB 2.0 7.1.18: a device answers within 6.5 bit times at the
device; the bus allows 16-18 round trip): `gaps` records each. Without
`timeout` (a receive-only device) no answer is expected.
"""

from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

J, K, SE0 = (0, 1), (1, 0), (0, 0)
DATA_PIDS = (0xC3, 0x4B)
TOKEN_PIDS = (0xE1, 0x69, 0x2D, 0xA5)
HANDSHAKE_PIDS = (0xD2, 0x5A, 0x1E)
IN = 0x69


def crc5(value, bits=11):
    """USB token CRC5 (x^5 + x^2 + 1) over `bits` bits, LSB first; the
    complemented remainder, to be sent LSB first."""
    crc = 0x1F
    for i in range(bits):
        bit = (value >> i) & 1
        if (crc & 1) ^ bit:
            crc = (crc >> 1) ^ 0x14
        else:
            crc >>= 1
    return crc ^ 0x1F


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def packet_bytes(data):
    """The bytes after SYNC for one host packet [PID, ...] (CRC added)."""
    pid = data[0]
    if (pid ^ (pid >> 4)) & 0xF != 0xF:
        raise ValueError(f"0x{pid:02X} is not a PID (its high nibble must complement the low)")
    if pid in TOKEN_PIDS:
        if pid == 0xA5:
            field = data[1] | data[2] << 8
        else:
            if len(data) != 3 or data[1] > 127 or data[2] > 15:
                raise ValueError("a token is [PID, address (0-127), endpoint (0-15)]")
            field = data[1] | data[2] << 7
        field |= crc5(field) << 11
        return [pid, field & 0xFF, field >> 8]
    if pid in DATA_PIDS:
        crc = crc16(bytes(data[1:]))
        return [pid, *data[1:], crc & 0xFF, crc >> 8]
    if len(data) != 1:
        raise ValueError("a handshake is the PID alone")
    return [pid]


def line_states(payload):
    """SYNC and `payload`, LSB first, stuffed and NRZI coded from J."""
    bits = [(b >> i) & 1 for b in [0x80, *payload] for i in range(8)]
    out, line, ones = [], J, 0
    for bit in bits:
        for b in ([bit, 0] if bit and ones == 5 else [bit]):
            if not b:
                line = K if line == J else J
            out.append(line)
        ones = 0 if not bit or ones == 5 else ones + 1
    return out


class UsbHost:
    def __init__(self, bus, dut, name, dp, dm, bit, idle=4, timeout=0):
        self.bus, self.dut, self.name = bus, dut, name
        self.dp, self.dm, self.bit = dp, dm, bit
        self.idle, self.timeout = idle, timeout
        self.received, self.problems, self.outbox, self.gaps = [], [], [], []
        self.sending = False
        self.expect_answer_after = None     # cycle of the host's last EOP end, if an answer is due
        self.cycle = 0

    def tasks(self):
        return [self._listen(), self._send(), self._idle()]

    def write(self, data):
        self.outbox.append(packet_bytes(list(data)))

    def chip_drives(self, pad):
        if hasattr(self.bus, 'chip_driven'):        # a bus that knows the chip's drive (the mesh benches)
            return self.bus.chip_driven(pad)
        return bool(int(self.dut.uio_oe.value) >> pad & 1)

    def chip_level(self, pad):
        if hasattr(self.bus, '_chip'):
            return self.bus._chip(self.bus.wires.get(pad, pad))[0]
        return int(self.dut.uio_out.value) >> pad & 1

    def _state(self):
        if not (self.chip_drives(self.dp) and self.chip_drives(self.dm)):
            return None
        return self.chip_level(self.dp), self.chip_level(self.dm)

    async def _idle(self):
        """Hold J while nobody sends (the USB pulls), released while the chip drives."""
        while True:
            await FallingEdge(self.dut.clk)
            if not self.sending:
                self._line(None if self.chip_drives(self.dp) or self.chip_drives(self.dm) else J)

    def _line(self, state):
        if state is None:
            self.bus.drive.pop((self.dp, self.name), None)
            self.bus.drive.pop((self.dm, self.name), None)
        else:
            self.bus.drive[(self.dp, self.name)], self.bus.drive[(self.dm, self.name)] = state

    async def _send(self):
        while True:
            if not self.outbox:
                await RisingEdge(self.dut.clk)
                continue
            payload = self.outbox.pop(0)
            # The chip's answer ends with a bit of J; the host's decoder has
            # its packet at mid-bit, so the chip may hold the bus half a bit
            # more (it must release it after its EOP's J).
            for _ in range(self.bit):
                if not (self.chip_drives(self.dp) or self.chip_drives(self.dm)):
                    break
                await RisingEdge(self.dut.clk)
            else:
                self.problems.append("the chip drove the bus when the host had a packet to send")
            self.sending = True
            for state in [J] * self.idle + line_states(payload) + [SE0, SE0, J]:
                self._line(state)
                await ClockCycles(self.dut.clk, self.bit)
            self.sending = False
            if self.timeout and (payload[0] in DATA_PIDS or payload[0] == IN):
                self.expect_answer_after = self.cycle
            # inter-packet gap before the host's next packet
            await ClockCycles(self.dut.clk, 2 * self.bit)

    async def _listen(self):
        previous = None
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1
            state = self._state()
            if self.expect_answer_after is not None and \
                    self.cycle - self.expect_answer_after > (self.timeout + self.idle) * self.bit:
                self.problems.append(f"no answer within {self.timeout} bit times of the host's packet")
                self.expect_answer_after = None
            if previous == J and state == K:
                if self.expect_answer_after is not None:
                    gap = (self.cycle - self.expect_answer_after) / self.bit
                    self.gaps.append(gap)
                    if gap < 2:
                        self.problems.append(f"the chip answered {gap:.1f} bit times after the host's EOP; at least 2")
                    self.expect_answer_after = None
                await self._packet()
                state = self._state()
            # A bus nobody drives idles at J (the pull-ups): a device that
            # takes the bus starting with SYNC's first K has sent J -> K.
            previous = J if state is None else state

    async def _packet(self):
        """Sample mid-bit from the first K until the line returns to J after SE0."""
        cycle, states, last, edges = 0, [], K, []
        while True:
            await RisingEdge(self.dut.clk)
            cycle += 1
            state = self._state()
            if state != last:
                edges.append(cycle)
                last = state
            if cycle % self.bit == self.bit // 2:
                states.append(state)
                if len(states) >= 3 and states[-1] == J and states[-2] == SE0:
                    break
                if len(states) > 2000:
                    self.problems.append("a packet never ended")
                    return
        # Transitions after the line goes idle again are the next packet's concern.
        late = [c for c in edges if c % self.bit and c < cycle]
        if late:
            self.problems.append(f"a transition {late[0] % self.bit} cycles off the bit grid")
        self._decode(states)

    def _decode(self, states):
        bits, ones, previous, index = [], 0, J, 0
        while index < len(states) and states[index] != SE0:
            bit = 1 if states[index] == previous else 0
            previous = states[index]
            index += 1
            if ones == 6:
                if bit:
                    self.problems.append("a 1 where a stuffed 0 must follow six 1s")
                ones = 0
                continue
            bits.append(bit)
            ones = ones + 1 if bit else 0
        se0 = 0
        while index < len(states) and states[index] == SE0:
            se0, index = se0 + 1, index + 1
        if se0 != 2:
            self.problems.append(f"end of packet had {se0} bits of SE0; it must have 2")
        if len(bits) % 8:
            self.problems.append(f"the packet had {len(bits)} bits, not whole bytes")
            return
        packet = [sum(bits[i + j] << j for j in range(8)) for i in range(0, len(bits), 8)]
        if not packet or packet[0] != 0x80:
            self.problems.append(f"SYNC was {packet[:1]}, not 0x80")
            return
        if len(packet) > 1 and packet[1] in DATA_PIDS:
            data, crc = packet[2:-2], packet[-2:]
            if len(packet) < 4 or crc16(bytes(data)) != crc[0] | crc[1] << 8:
                self.problems.append("the CRC16 of data packet [" + ", ".join(f"0x{b:02X}" for b in packet) + "] is wrong")
                return
            packet = packet[:-2]
        self.received.extend(packet[1:])
