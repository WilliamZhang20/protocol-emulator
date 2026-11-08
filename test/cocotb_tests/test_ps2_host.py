"""PS/2 host on the spatial fabric: commands to a keyboard model, its ACK
and replies back, on the same two open-drain lines."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import driven_level, reset_top, start_clock, wait_until_halted
from cocotb_tests.fabric import Bus, load_program, pop_rx, rx_empty, select_channel, start_engine
from cocotb_tests.protocols import PS2_CLK, PS2_DATA, ps2_host

HALF = 200            # scaled-down device clock half period
INHIBIT = 600         # host CLK low time (100 us at real scale)


class Keyboard:
    """Waits for a host request (CLK held low, then DATA low and CLK
    released), clocks in 8 bits, parity and stop, ACKs, then answers 0xFA
    and, for 0xFF (reset), the self-test result 0xAA."""

    def __init__(self, dut, bus: Bus) -> None:
        self.dut, self.bus = dut, bus
        self.commands: list[int] = []
        self.inhibits: list[int] = []
        self.errors: list[str] = []
        cocotb.start_soon(self._monitor())
        cocotb.start_soon(self._run())

    async def _monitor(self) -> None:
        """Every interval the host itself pulls CLK low."""
        low = None
        while True:
            await RisingEdge(self.dut.clk)
            pulling = driven_level(self.dut, PS2_CLK) == 0
            if pulling and low is None:
                low = 0
            elif pulling:
                low += 1
            elif low is not None:
                self.inhibits.append(low + 1)
                low = None

    async def _clock(self) -> int:
        """One device clock; return DATA sampled at the rising edge."""
        await ClockCycles(self.dut.clk, HALF // 2)
        self.bus.drive[PS2_CLK] = 0
        await ClockCycles(self.dut.clk, HALF)
        self.bus.drive[PS2_CLK] = None
        bit = self.bus.level(PS2_DATA)
        await ClockCycles(self.dut.clk, HALF // 2)
        return bit

    async def _send(self, value: int) -> None:
        bits = [0] + [(value >> i) & 1 for i in range(8)]
        bits += [1 - (sum(bits[1:]) & 1), 1]
        for bit in bits:
            self.bus.drive[PS2_DATA] = bit
            await ClockCycles(self.dut.clk, HALF // 2)
            self.bus.drive[PS2_CLK] = 0
            await ClockCycles(self.dut.clk, HALF)
            self.bus.drive[PS2_CLK] = None
            await ClockCycles(self.dut.clk, HALF // 2)
        self.bus.drive[PS2_DATA] = None

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            if self.bus.level(PS2_CLK):
                continue
            while not self.bus.level(PS2_CLK):          # host inhibit
                await RisingEdge(self.dut.clk)
            if self.bus.level(PS2_DATA):
                self.errors.append("no start bit after inhibit")
                continue
            await ClockCycles(self.dut.clk, HALF)
            bits = [await self._clock() for _ in range(10)]     # data, parity, stop
            value = sum(b << i for i, b in enumerate(bits[:8]))
            if bits[8] != 1 - (sum(bits[:8]) & 1):
                self.errors.append("parity")
            if bits[9] != 1:
                self.errors.append("stop bit not released")
            self.bus.drive[PS2_DATA] = 0                 # ACK
            await self._clock()
            self.bus.drive[PS2_DATA] = None
            self.commands.append(value)
            await ClockCycles(self.dut.clk, 4 * HALF)
            await self._send(0xFA)
            if value == 0xFF:
                await ClockCycles(self.dut.clk, 4 * HALF)
                await self._send(0xAA)


@cocotb.test()
async def test_ps2_host_commands(dut):
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    kbd = Keyboard(dut, bus)
    commands = [0xFF, 0xED, 0x07]           # reset; set LEDs; LED mask
    await load_program(dut, ps2_host([(0xFF, 2), (0xED, 1), (0x07, 1)], INHIBIT))
    await start_engine(dut)
    await wait_until_halted(dut, timeout_cycles=400000)
    assert not kbd.errors, kbd.errors
    assert kbd.commands == commands, kbd.commands
    assert kbd.inhibits == [INHIBIT] * len(commands), kbd.inhibits
    acks = []
    while not await rx_empty(dut):
        acks.append(await pop_rx(dut))
    assert acks == [0, 0, 0], acks
    await select_channel(dut, 1)
    replies = []
    while not await rx_empty(dut):
        replies.append(await pop_rx(dut))
    assert replies == [0xFA, 0xAA, 0xFA, 0xFA], replies
