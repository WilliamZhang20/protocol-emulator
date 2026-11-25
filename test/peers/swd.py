"""Reference SW-DP: line reset, selection, requests, ACK, data and parity.

Adapted from the hardware repository's reference target. Implements the
successful DP path; AP accesses and WAIT/FAULT responses are outside this peer.
"""
from cocotb.triggers import RisingEdge

IDCODE = 0x2BA0_1477
JTAG_TO_SWD = 0xE79E


def parity(v: int) -> int:
    return bin(v).count("1") & 1


def request(ap: int, read: int, addr: int) -> int:
    a2, a3 = (addr >> 2) & 1, (addr >> 3) & 1
    bits = [1, ap, read, a2, a3, ap ^ read ^ a2 ^ a3, 0, 1]
    return sum(b << i for i, b in enumerate(bits))


class SwdTarget:
    """SW-DP: samples host bits on SWCLK rising edges, drives its own bits
    right after a rising edge (the host samples on the next falling one).
    Tracks line resets, the JTAG-to-SWD switch, and DP register reads and
    writes (IDCODE at 0 read, SELECT at 8 write, RDBUFF at C read)."""

    def __init__(self, bus, dut, name, swclk, swdio) -> None:
        self.name, self.swclk, self.swdio = name, swclk, swdio
        self.received, self.problems = [], []
        self.dut, self.bus = dut, bus
        self.history: list[int] = []
        self.ones = 0
        self.swd = False
        self.writes: list[tuple[int, int]] = []
        self.select = 0
        self.errors = self.problems


    def tasks(self):
        return [self._run()]

    def write(self, data):
        raise ValueError("write DP registers over SWD")

    def chip_drives(self, pad):
        return bool(int(self.dut.uio_oe.value) >> pad & 1)

    def clk(self) -> int:
        return 0 if not self.chip_drives(self.swclk) else self.bus.level(self.swclk)

    async def _edge(self) -> int:
        """Wait for the next SWCLK rising edge; return SWDIO there."""
        previous = self.clk()
        while True:
            await RisingEdge(self.dut.clk)
            now = self.clk()
            if now and not previous:
                return self.bus.level(self.swdio)
            previous = now

    async def _bits(self, n: int) -> int:
        value = 0
        for i in range(n):
            value |= (await self._edge()) << i
        return value

    async def _drive(self, value: int, n: int) -> None:
        """Drive n bits, each from just after a rising edge to the next."""
        for i in range(n):
            self.bus.drive[(self.swdio, self.name)] = (value >> i) & 1
            if self.chip_drives(self.swdio):
                self.errors.append("contention: host drives during target bits")
            await self._edge()
        self.bus.drive.pop((self.swdio, self.name), None)

    async def _run(self) -> None:
        while True:
            bit = await self._edge()
            self.history.append(bit)
            self.ones = self.ones + 1 if bit else 0
            if self.ones >= 50:
                self.reset = True
            tail = self.history[-16:]
            if len(tail) == 16 and sum(b << i for i, b in enumerate(tail)) == JTAG_TO_SWD:
                self.swd = True
            if not (self.swd and bit == 1 and self.ones == 1 and
                    len(self.history) > 1 and self.history[-2] == 0):
                continue
            # A start bit after an idle low: the rest of the request.
            rest = await self._bits(7)
            ap, rnw, a2, a3, par, stop, park = [(rest >> i) & 1 for i in range(7)]
            self.history += [ap, rnw, a2, a3, par, stop, park]
            if par != ap ^ rnw ^ a2 ^ a3 or stop != 0 or park != 1:
                self.errors.append(f"bad request {rest:07b}")
                continue
            addr = (a2 << 2) | (a3 << 3)
            await self._edge()                      # turnaround
            if rnw:
                value = IDCODE if addr == 0 else 0xC0FFEE00 | self.select
                await self._drive(0b001 | (value << 3) | (parity(value) << 35), 36)
                await self._edge()                  # turnaround back to the host
            else:
                await self._drive(0b001, 3)         # ACK OK
                await self._edge()                  # turnaround
                data = await self._bits(32)
                p = await self._bits(1)
                if p != parity(data):
                    self.errors.append("write parity")
                self.writes.append((addr, data))
                self.received += list(data.to_bytes(4, "little"))
                if addr == 8:
                    self.select = data & 0xFF
            self.history = [0]
            self.ones = 0

