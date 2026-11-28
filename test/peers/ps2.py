"""A PS/2 keyboard: device-to-host transmitter with odd parity, and the
host-to-device command receiver.

Both wires use open-drain drive (zero or release); data settles before each
falling sampling edge. bad_parity/bad_stop allow negative receiver tests.

Host to device: when the host has held CLK low for at least `inhibit`
clocks (the request to send; 100 us on a real bus), counted from when the
keyboard itself lets go of CLK, and then released it
with DATA low, the keyboard clocks the command in: eleven clocks, sampling
DATA on each rising edge (start 0, eight data bits LSB first, odd parity,
stop 1), then a twelfth in which it acknowledges by holding DATA low. A
command goes to `received`, and the keyboard answers it with 0xFA (ACK),
as keyboards do. As a referee it fails the test when the host changes
DATA while CLK is high in a command, or sends a bad start, parity or stop.
"""
from cocotb.triggers import ClockCycles


class Ps2Keyboard:
    def __init__(self, bus, dut, name, clk, data, half=2000, bad_parity=False, bad_stop=False, inhibit=5000):
        if half < 8:
            raise ValueError("PS/2 half period needs at least eight core cycles")
        self.bus, self.dut, self.name = bus, dut, name
        self.clk, self.data, self.half = clk, data, half
        self.bad_parity, self.bad_stop = bad_parity, bad_stop
        self.inhibit = inhibit
        self.outbox, self.received, self.problems, self.requests = [], [], [], []

    def tasks(self):
        return [self.run(), self._watch()]

    async def _watch(self):
        """The host's request to send: count how long the host alone holds CLK
        low (a keyboard times it from when it lets go of CLK), and note each
        release with DATA's level then."""
        held = 0
        while True:
            await ClockCycles(self.dut.clk, 1)
            if (self.clk, self.name) not in self.bus.drive and not self.bus.level(self.clk):
                held += 1
            else:
                if held and (self.clk, self.name) not in self.bus.drive:
                    self.requests.append((held, self.bus.level(self.data)))
                held = 0

    def write(self, data):
        self.outbox.extend(data)

    def drive(self, pin, level):
        if level:
            self.bus.drive.pop((pin, self.name), None)
        else:
            self.bus.drive[(pin, self.name)] = 0

    async def _command(self):
        """Clock a host command in (CLK released, DATA low: the start bit)."""
        bits = []
        for _ in range(11):
            await ClockCycles(self.dut.clk, self.half)
            self.drive(self.clk, 0)
            await ClockCycles(self.dut.clk, self.half)
            self.drive(self.clk, 1)
            await ClockCycles(self.dut.clk, 2)
            level = self.bus.level(self.data)
            bits.append(level)
            for _ in range(self.half // 2):
                await ClockCycles(self.dut.clk, 1)
                if self.bus.level(self.data) != level:
                    self.problems.append("the host changed DATA while CLK was high in a command")
                    break
        start, data, parity, stop = bits[0], bits[1:9], bits[9], bits[10]
        byte = sum(b << i for i, b in enumerate(data))
        if start != 0 or stop != 1 or parity != 1 ^ (sum(data) & 1):
            self.problems.append(f"bad host command frame (start {start}, parity {parity}, stop {stop})")
            return
        # Acknowledge: DATA low through a twelfth clock.
        await ClockCycles(self.dut.clk, self.half // 2)
        self.drive(self.data, 0)
        await ClockCycles(self.dut.clk, self.half // 2)
        self.drive(self.clk, 0)
        await ClockCycles(self.dut.clk, self.half)
        self.drive(self.clk, 1)
        await ClockCycles(self.dut.clk, self.half // 2)
        self.drive(self.data, 1)
        self.received.append(byte)
        self.outbox.append(0xFA)
        await ClockCycles(self.dut.clk, 2 * self.half)

    async def run(self):
        while True:
            if self.requests:
                held, data = self.requests.pop(0)
                if held < self.inhibit:
                    self.problems.append(f"the host held CLK low for {held} clocks, less than {self.inhibit}")
                elif not data:
                    await self._command()
                continue
            if not self.outbox:
                await ClockCycles(self.dut.clk, 1)
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
