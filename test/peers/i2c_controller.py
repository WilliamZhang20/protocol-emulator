"""An I2C controller on open-drain SCL and SDA, for testing a target.

`write(message)` queues one message: an address byte (7-bit address and the
R/W bit, as sent) followed by data bytes. The controller sends a START, the
message, and a STOP. A message queued while another is in progress follows
it with a repeated START instead of a STOP in between, as a controller does
for a combined transaction.

After every byte it reads the acknowledge bit; `received` holds one entry
per byte sent: 0 for ACK, 1 for NAK. After a NAK the rest of that message
is not sent and the controller ends with a STOP (or a repeated START into
the next queued message).

Timing, in clock cycles: SCL is low for `half` and high for `half`; SDA
changes `hold` cycles after SCL falls (so it is set up `half - hold` before
SCL rises). A target holding SCL low stretches the low phase.

As a referee it fails the test when the target pulls SDA low while SCL is
high in a bit the controller sends (anything but an acknowledge), or when
SDA changes while SCL is high during an acknowledge bit.
"""

from cocotb.triggers import ClockCycles, RisingEdge


class I2cController:
    def __init__(self, bus, dut, name, scl, sda, half, hold=1):
        if not 1 <= hold < half:
            raise ValueError("I2C controller: need 1 <= hold < half")
        self.bus, self.dut, self.name = bus, dut, name
        self.scl, self.sda, self.half, self.hold = scl, sda, half, hold
        self.queue, self.received, self.problems = [], [], []
        self.sda_out, self.scl_out = 1, 1
        self.checking_ack = False

    def tasks(self):
        return [self._run(), self._referee()]

    def write(self, data):
        self.queue.append(list(data))

    def _drive(self, pin, level):
        if level:
            self.bus.drive.pop((pin, self.name), None)
        else:
            self.bus.drive[(pin, self.name)] = 0

    def _set_sda(self, level):
        self.sda_out = level
        self._drive(self.sda, level)

    def _set_scl(self, level):
        self.scl_out = level
        self._drive(self.scl, level)

    async def _scl_high(self):
        """Release SCL and wait until it is high (a target may stretch)."""
        self._set_scl(1)
        while not self.bus.level(self.scl):
            await RisingEdge(self.dut.clk)

    async def _bit(self, level):
        """One bit from SCL low: change SDA after the hold time, then clock it.
        Returns SDA sampled in the middle of SCL high."""
        await ClockCycles(self.dut.clk, self.hold)
        self._set_sda(level)
        await ClockCycles(self.dut.clk, self.half - self.hold)
        await self._scl_high()
        await ClockCycles(self.dut.clk, self.half // 2)
        sample = self.bus.level(self.sda)
        await ClockCycles(self.dut.clk, self.half - self.half // 2)
        self._set_scl(0)
        return sample

    async def _start(self):
        """From idle (both high) or from SCL low after an acknowledge
        (a repeated START): SDA falls while SCL is high, then SCL falls."""
        if not self.scl_out:
            await ClockCycles(self.dut.clk, self.hold)
            self._set_sda(1)
            await ClockCycles(self.dut.clk, self.half - self.hold)
            await self._scl_high()
        await ClockCycles(self.dut.clk, self.half)
        self._set_sda(0)
        await ClockCycles(self.dut.clk, self.half)
        self._set_scl(0)

    async def _stop(self):
        await ClockCycles(self.dut.clk, self.hold)
        self._set_sda(0)
        await ClockCycles(self.dut.clk, self.half - self.hold)
        await self._scl_high()
        await ClockCycles(self.dut.clk, self.half)
        self._set_sda(1)
        await ClockCycles(self.dut.clk, self.half)

    async def _run(self):
        while True:
            while not self.queue:
                await RisingEdge(self.dut.clk)
            await self._start()
            while True:
                message = self.queue.pop(0)
                for byte in message:
                    for k in range(7, -1, -1):
                        await self._bit(byte >> k & 1)
                    self.checking_ack = True
                    ack = await self._bit(1)
                    self.checking_ack = False
                    self.received.append(ack)
                    if ack:
                        break
                if not self.queue:
                    break
                await self._start()       # repeated START into the next message
            await self._stop()

    async def _referee(self):
        prev_scl, prev_sda = 1, 1
        while True:
            await RisingEdge(self.dut.clk)
            scl, sda = self.bus.level(self.scl), self.bus.level(self.sda)
            if scl and prev_scl:
                if self.checking_ack:
                    if sda != prev_sda:
                        self.problems.append("SDA changed while SCL was high during an acknowledge")
                elif sda == 0 and self.sda_out == 1:
                    self.problems.append("the target pulled SDA low while SCL was high outside an acknowledge")
            prev_scl, prev_sda = scl, sda
