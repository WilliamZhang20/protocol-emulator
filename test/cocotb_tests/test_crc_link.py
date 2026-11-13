"""Linked CRC tails at the shifter's maximum one-bit-per-clock rate.

The test uses host commands and a GPIO pin only, so it runs in RTL and GL.
"""

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock, wait_until_halted
from cocotb_tests.fabric import (
    Bus, MODE_PUSH_PULL, ONE, Px8, load_program, push_tx, select_channel,
    shifter_out, shifter_stop, start_engine,
)


def crc8(byte: int) -> int:
    crc = 0
    for shift in range(7, -1, -1):
        feedback = ((crc >> 7) & 1) ^ ((byte >> shift) & 1)
        crc = ((crc << 1) & 0xFF) ^ (0x07 if feedback else 0)
    return crc


@cocotb.test()
@cocotb.parametrize(channel=[0, 1])
async def test_linked_crc_tail_at_one_clock_per_bit(dut, channel):
    """The CRC absorbs the last data bit and emits each FCS bit in time."""
    await start_clock(dut, 20)
    await reset_top(dut)
    p = Px8()
    p.shifter(channel, msb=True, idle=1, shift=ONE)
    p.shifter_io(channel, pull=True)
    p.shifter_coder(channel, tail=8, tail_invert=True)
    p.crc(width=8, poly=0x07, check=0, link=channel,
          init_ones=False, tile=channel)
    p.pin_cell(0, src=shifter_out(channel), mode=MODE_PUSH_PULL)
    p.arm()
    p.wev(shifter_stop(channel))
    p.halt()
    await load_program(dut, p.assemble())
    await start_engine(dut)
    await select_channel(dut, channel)
    bus = Bus(dut)

    async def record():
        levels = []
        for _ in range(350):
            await RisingEdge(dut.clk)
            levels.append(bus.level(0))
        return levels

    task = cocotb.start_soon(record())
    byte = [0x01, 0x23][channel]  # Both start with 0 for an unambiguous edge.
    await push_tx(dut, byte)
    await wait_until_halted(dut, timeout_cycles=2000, poll_every=8)
    levels = await task
    start = next(i for i in range(1, len(levels))
                 if levels[i - 1] == 1 and levels[i] == 0)
    observed = levels[start:start + 16]
    expected_word = (byte << 8) | crc8(byte)
    expected = [(expected_word >> shift) & 1 for shift in range(15, -1, -1)]
    assert observed == expected, (
        f"channel={channel} observed={''.join(map(str, observed))} "
        f"expected={''.join(map(str, expected))}"
    )
