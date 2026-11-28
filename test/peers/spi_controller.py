"""An SPI controller, mode 0 (CPOL 0, CPHA 0), MSB first, for testing a
target.

`write(data)` queues one transaction: CS falls, the controller exchanges
the bytes (MOSI changes while SCK is low and is sampled on its rise; MISO
is sampled on SCK's rise), then CS rises, with `gap` clocks of CS high
before the next. `received` holds every MISO byte, in order. SCK is low for
`half` clocks and high for `half`; CS falls `half` clocks before the first
rise and rises `half` after the last fall.

As a referee it fails the test when the target drives MISO while CS is high
(the bus is shared), leaves it undriven while CS is low (each with half
of `half` clocks to follow CS through its synchroniser), or changes it
while SCK is high (mode 0: MISO changes only after SCK falls or CS falls).
"""

from cocotb.triggers import ClockCycles, RisingEdge


class SpiController:
    def __init__(self, bus, dut, name, cs, sck, mosi, miso, half, gap=8):
        if half < 2:
            raise ValueError("SPI controller: half must be at least 2 clocks")
        self.bus, self.dut, self.name = bus, dut, name
        self.cs, self.sck, self.mosi, self.miso = cs, sck, mosi, miso
        self.half, self.gap = half, gap
        self.queue, self.received, self.problems = [], [], []
        self.selected = False

    def tasks(self):
        return [self._run(), self._referee()]

    def write(self, data):
        self.queue.append(list(data))

    def _set(self, pin, level):
        self.bus.drive[(pin, self.name)] = level

    async def _run(self):
        self._set(self.cs, 1)
        self._set(self.sck, 0)
        self._set(self.mosi, 1)
        while True:
            while not self.queue:
                await RisingEdge(self.dut.clk)
            data = self.queue.pop(0)
            self._set(self.cs, 0)
            self.selected = True
            for byte in data:
                got = 0
                for k in range(7, -1, -1):
                    self._set(self.mosi, byte >> k & 1)
                    await ClockCycles(self.dut.clk, self.half)
                    self._set(self.sck, 1)
                    got = got << 1 | self.bus.level(self.miso)
                    await ClockCycles(self.dut.clk, self.half)
                    self._set(self.sck, 0)
                self.received.append(got)
            await ClockCycles(self.dut.clk, self.half)
            self._set(self.cs, 1)
            self.selected = False
            self._set(self.mosi, 1)
            await ClockCycles(self.dut.clk, self.gap)

    async def _referee(self):
        prev_sck, prev_miso, low_for, high_for = 0, None, 0, 0
        while True:
            await RisingEdge(self.dut.clk)
            sck, driven = self.bus.level(self.sck), self.bus.chip_driven(self.miso)
            miso = self.bus.level(self.miso)
            if not self.selected:
                low_for, high_for = 0, high_for + 1
                # Like taking MISO, releasing it waits for the target's
                # synchroniser: a few clocks after CS rises.
                if driven and high_for > self.half // 2:
                    self.problems.append("the target drove MISO while CS was high")
            else:
                low_for, high_for = low_for + 1, 0
                # The target sees CS through its synchroniser: a few clocks to take MISO.
                if not driven and low_for > self.half // 2:
                    self.problems.append("the target left MISO undriven while CS was low")
                if sck and prev_sck and prev_miso is not None and miso != prev_miso:
                    self.problems.append("MISO changed while SCK was high")
            prev_sck, prev_miso = sck, miso
