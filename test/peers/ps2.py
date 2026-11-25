"""Device-to-host PS/2 reference transmitter with odd parity.

Both wires use open-drain drive (zero or release); data settles before each
falling sampling edge. bad_parity/bad_stop allow negative receiver tests.
"""
from cocotb.triggers import ClockCycles


class Ps2Keyboard:
    def __init__(self, bus, dut, name, clk, data, half=2000, bad_parity=False, bad_stop=False):
        if half < 8:
            raise ValueError("PS/2 half period needs at least eight core cycles")
        self.bus, self.dut, self.name = bus, dut, name
        self.clk, self.data, self.half = clk, data, half
        self.bad_parity, self.bad_stop = bad_parity, bad_stop
        self.outbox, self.received, self.problems = [], [], []

    def tasks(self):
        return [self.run()]

    def write(self, data):
        self.outbox.extend(data)

    def drive(self, pin, level):
        if level:
            self.bus.drive.pop((pin, self.name), None)
        else:
            self.bus.drive[(pin, self.name)] = 0

    async def run(self):
        while True:
            if not self.outbox:
                await ClockCycles(self.dut.clk, 8)
                continue
            byte = self.outbox.pop(0)
            parity = 1 ^ (byte.bit_count() & 1) ^ bool(self.bad_parity)
            frame = [0, *((byte >> i) & 1 for i in range(8)), parity, 0 if self.bad_stop else 1]
            for bit in frame:
                self.drive(self.data, bit)
                await ClockCycles(self.dut.clk, self.half)
                self.drive(self.clk, 0)
                await ClockCycles(self.dut.clk, self.half)
                self.drive(self.clk, 1)
            self.drive(self.data, 1)
            await ClockCycles(self.dut.clk, 2 * self.half)
