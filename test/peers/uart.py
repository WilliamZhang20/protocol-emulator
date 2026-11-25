"""A UART device: a terminal or another microcontroller on the serial lines.

It receives 8N1 frames on `from_chip` and sends them on `to_chip`, `bit`
cycles per bit. As a referee it checks that the chip holds every bit steady
across the middle half of its bit time (a wrong baud rate or a glitch fails
this) and that every stop bit is 1.
"""

from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge


class UartDevice:
    def __init__(self, bus, dut, name, from_chip, to_chip, bit, parity="none"):
        self.bus, self.dut, self.name = bus, dut, name
        # Spatial string arguments arrive as UTF-8 byte lists in the test plan.
        if isinstance(parity, list):
            parity = bytes(parity).decode("utf-8")
        if parity not in ("none", "even", "odd"):
            raise ValueError("UART parity must be none, even or odd")
        self.parity = parity
        self.rx_pad, self.tx_pad, self.bit = from_chip, to_chip, bit
        self.received, self.outbox, self.problems = [], [], []

    def tasks(self):
        return [self._listen(), self._transmit()]

    def write(self, data):
        self.outbox.extend(data)

    async def _listen(self):
        while True:
            await RisingEdge(self.dut.clk)
            if self.bus.level(self.rx_pad) == 0:
                # The next start bit can begin exactly when the previous
                # frame's stop-bit sampling finishes. If so, this coroutine
                # resumes after that falling edge and would otherwise miss
                # the start while awaiting the next rising edge.
                while self.bus.level(self.rx_pad) == 0:
                    await self._receive_frame()

    async def _sample_bit(self, label):
        """Sample the bit near its midpoint and check stability when the bit
        period leaves enough cycles for three independent samples."""
        if self.bit == 1:
            await FallingEdge(self.dut.clk)
            sample = self.bus.level(self.rx_pad)
            await RisingEdge(self.dut.clk)
            return sample
        if self.bit < 4:
            half = self.bit // 2
            await ClockCycles(self.dut.clk, half)
            sample = self.bus.level(self.rx_pad)
            await ClockCycles(self.dut.clk, self.bit - half)
            return sample
        quarter = self.bit // 4
        samples = []
        for _ in range(3):
            await ClockCycles(self.dut.clk, quarter)
            samples.append(self.bus.level(self.rx_pad))
        await ClockCycles(self.dut.clk, self.bit - 3 * quarter)
        if len(set(samples)) > 1:
            self.problems.append(
                f"{label} bit changed in the middle of its bit time "
                f"(baud rate mismatch?): samples={samples}"
            )
        return samples[1]

    async def _receive_frame(self):
        if await self._sample_bit("start") != 0:
            self.problems.append("a start bit was shorter than half a bit")
            return
        byte = 0
        for i in range(8):
            byte |= await self._sample_bit(f"data {i}") << i
        if self.parity != "none":
            expected = (byte.bit_count() & 1) ^ (self.parity == "odd")
            if await self._sample_bit("parity") != expected:
                self.problems.append(f"wrong {self.parity} parity after 0x{byte:02X}")
        if await self._sample_bit("stop") != 1:
            self.problems.append(f"the stop bit after 0x{byte:02X} was 0")
        self.received.append(byte)

    async def _transmit(self):
        while True:
            if not self.outbox:
                await ClockCycles(self.dut.clk, 8)
                continue
            byte = self.outbox.pop(0)
            parity = [] if self.parity == "none" else [(byte.bit_count() & 1) ^ (self.parity == "odd")]
            for level in [0, *((byte >> i) & 1 for i in range(8)), *parity, 1]:
                self.bus.drive[(self.tx_pad, self.name)] = level
                await ClockCycles(self.dut.clk, self.bit)
            del self.bus.drive[(self.tx_pad, self.name)]
