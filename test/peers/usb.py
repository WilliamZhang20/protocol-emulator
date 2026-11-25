"""A low-speed USB host listening on D+ and D-, `bit` cycles per bit.

It decodes each packet (NRZI, bit stuffing) and checks it as a referee:
every transition lies on the bit grid of the packet's first edge, SYNC is
0x80, a stuffed 0 follows every six 1s, a data packet's CRC16 is right, and
the packet ends with exactly two bits of SE0 and then J. `received` holds
each packet's PID and data bytes (SYNC and CRC removed).
"""

from cocotb.triggers import RisingEdge

J, K, SE0 = (0, 1), (1, 0), (0, 0)
DATA_PIDS = (0xC3, 0x4B)


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


class UsbHost:
    def __init__(self, bus, dut, name, dp, dm, bit):
        self.bus, self.dut, self.name = bus, dut, name
        self.dp, self.dm, self.bit = dp, dm, bit
        self.received, self.problems = [], []

    def tasks(self):
        return [self._listen()]

    def write(self, data):
        self.problems.append("this peer only listens")

    def _state(self):
        if not (self.bus.driven(self.dp) and self.bus.driven(self.dm)):
            return None
        return self.bus.level(self.dp), self.bus.level(self.dm)

    async def _listen(self):
        previous = None
        while True:
            await RisingEdge(self.dut.clk)
            state = self._state()
            if previous == J and state == K:
                await self._packet()
                state = self._state()
            previous = state

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
