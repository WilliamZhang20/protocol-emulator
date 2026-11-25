"""An SPI device (peripheral), MSB first, in any of the four modes.

While `cs` is low it samples `mosi` and drives `miso` on the edges `mode`
defines, answering with `replies` one byte per byte received (then 0).
As a referee it checks that SCK rests at its idle level whenever CS falls,
never moves while CS is high, that MOSI holds steady into every sampling
edge, and that CS only rises between whole bytes.
"""

from cocotb.triggers import RisingEdge


class SpiDevice:
    def __init__(self, bus, dut, name, cs, sck, mosi, miso, mode, replies):
        self.bus, self.dut, self.name = bus, dut, name
        self.cs, self.sck, self.mosi, self.miso = cs, sck, mosi, miso
        self.cpol, self.cpha = mode >> 1, mode & 1
        self.replies = list(replies)
        self.received, self.problems = [], []

    def tasks(self):
        return [self._run()]

    def write(self, data):
        self.replies.extend(data)

    def _next(self):
        """The next reply, left queued until its first bit is sampled."""
        return self.replies[0] if self.replies else 0

    def _drive(self, level):
        self.bus.drive[(self.miso, self.name)] = level

    async def _run(self):
        await RisingEdge(self.dut.clk)
        cs, sck, mosi = (self.bus.level(p) for p in (self.cs, self.sck, self.mosi))
        bits = shift_in = out = 0
        sck_driven = self.bus.driven(self.sck)
        while True:
            await RisingEdge(self.dut.clk)
            now_cs, now_sck, now_mosi = (self.bus.level(p) for p in (self.cs, self.sck, self.mosi))
            if cs and not now_cs:  # selected
                if now_sck != self.cpol:
                    self.problems.append(f"SCK was {now_sck} when CS fell; mode {2 * self.cpol + self.cpha} idles at {self.cpol}")
                bits, shift_in = 0, 0
                out = self._next()
                if self.cpha == 0:
                    self._drive(out >> 7 & 1)
            elif not cs and now_cs:  # released
                if bits % 8:
                    self.problems.append(f"CS rose after {bits % 8} bits of a byte")
                self.bus.drive.pop((self.miso, self.name), None)
            # SCK going from floating to driven (the fabric arming) is not an edge.
            if now_sck != sck and self.bus.driven(self.sck) and sck_driven:
                if now_cs:
                    self.problems.append("SCK moved while CS was high")
                else:
                    leading = now_sck != self.cpol
                    if leading == (self.cpha == 0):  # the sampling edge
                        if now_mosi != mosi:
                            self.problems.append("MOSI changed on the same cycle as the sampling edge")
                        if bits % 8 == 0 and self.replies:
                            self.replies.pop(0)  # this byte is now really being sent
                        shift_in = (shift_in << 1 | now_mosi) & 0xFF
                        bits += 1
                        if bits % 8 == 0:
                            self.received.append(shift_in)
                    else:  # the shifting edge: present the next bit
                        position = bits % 8
                        # A new byte starts here, except the first one in mode 1 and 3,
                        # which was loaded when CS fell.
                        if position == 0 and (bits or self.cpha == 0):
                            out = self._next()
                        self._drive(out >> (7 - position) & 1)
            cs, sck, mosi = now_cs, now_sck, now_mosi
            sck_driven = self.bus.driven(self.sck)
