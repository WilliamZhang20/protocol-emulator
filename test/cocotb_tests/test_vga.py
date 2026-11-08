"""VGA: every sync edge and every pixel cell checked cycle by cycle."""

import random

import cocotb
from cocotb.triggers import RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import load_program, push_tx, start_engine, tx_full
from cocotb_tests.protocols import VGA_COLOR, VGA_HSYNC, VGA_VSYNC, vga, vga_framebuffer


class Timing:
    def __init__(self, cell, cells, front, sync, back, v_visible, v_front, v_sync, v_back):
        self.args = (cell, cells, front, sync, back, v_visible, v_front, v_sync, v_back)
        self.cell, self.cells = cell, cells
        self.front, self.sync, self.back = front, sync, back
        self.visible = cell * cells
        self.line = self.visible + front + sync + back
        self.v_visible, self.v_front, self.v_sync = v_visible, v_front, v_sync
        self.frame = v_visible + v_front + v_sync + v_back
        self.bytes_per_line = cells // 8


async def feed(dut, timing: Timing, image: list[list[int]]) -> None:
    """The host streams the image's lines, frame after frame."""
    while True:
        for row in image:
            for i, byte in enumerate(row):
                while await tx_full(dut):
                    pass
                await push_tx(dut, byte, eop=i == len(row) - 1)


async def check(dut, timing: Timing, image: list[list[int]], frames: float) -> int:
    """Compare every pin, every cycle, from the first HSYNC fall on, with
    the waveform the timing defines. Returns the number of lines checked."""
    t = timing
    cycle, first_fall, prev_hs = 0, None, 1
    errors: list[str] = []
    end = None
    while True:
        await RisingEdge(dut.clk)
        cycle += 1
        out = int(dut.uio_out.value)
        oe = int(dut.uio_oe.value)
        hs, vs = (out >> VGA_HSYNC) & 1, (out >> VGA_VSYNC) & 1
        colors = {(out >> p) & 1 for p in VGA_COLOR}
        if first_fall is None:
            if oe and not hs and prev_hs:
                first_fall = cycle
                end = cycle + int(frames * t.frame * t.line)
            else:
                prev_hs = hs
                continue
        assert len(colors) == 1, "colour pins disagree"
        pixel = colors.pop()
        # Line k: HSYNC falls at first_fall + k * line; its pixels end
        # `front` before that and its VSYNC level is set a cycle before
        # its first pixel.
        k, at = divmod(cycle - first_fall + t.front + t.visible, t.line)
        row = k % t.frame
        expect_hs = 0 if t.front + t.visible <= at < t.front + t.visible + t.sync else 1
        if at < t.visible and row < t.v_visible:
            cell_index = at // t.cell
            data = image[(k // t.frame * t.v_visible + row) % len(image)]
            expect_px = (data[cell_index // 8] >> (7 - cell_index % 8)) & 1
        else:
            expect_px = 0
        vk = k if at < t.line - 1 else k + 1        # VSYNC changes a cycle before line k+1
        vrow = vk % t.frame
        expect_vs = 0 if t.v_visible + t.v_front <= vrow < t.v_visible + t.v_front + t.v_sync else 1
        for name, got, want in (("HSYNC", hs, expect_hs), ("pixel", pixel, expect_px),
                                ("VSYNC", vs, expect_vs)):
            if got != want and len(errors) < 8:
                errors.append(f"{name} {got} at line {k} (row {row}) +{at}")
        if cycle >= end:
            assert not errors, errors
            return int(frames * t.frame)


async def run(dut, timing: Timing, frames: float, clock_ns: int = 20, seed: int = 1) -> int:
    await start_clock(dut, clock_ns)
    await reset_top(dut)
    rng = random.Random(seed)
    image = [[rng.randrange(256) for _ in range(timing.bytes_per_line)]
             for _ in range(timing.v_visible)]
    image[0] = [0xFF] * timing.bytes_per_line           # full white line
    image[-1] = [0xAA] * timing.bytes_per_line          # one-cell stripes
    await load_program(dut, vga(*timing.args))
    await start_engine(dut)
    cocotb.start_soon(feed(dut, timing, image))
    return await check(dut, timing, image, frames)


@cocotb.test()
async def test_vga_small_frames(dut):
    """Small timing, three frames: HSYNC period and width, every pixel
    cell's place and value, black porches and blank lines, VSYNC lines."""
    timing = Timing(4, 16, 6, 10, 8, 4, 2, 2, 3)
    assert await run(dut, timing, frames=3) == 3 * timing.frame


@cocotb.test()
async def test_vga_640x480(dut):
    """640 x 480 at 50 MHz (59.5 Hz, 31.25 kHz lines), one whole frame
    and into the next."""
    timing = Timing(16, 80, 32, 192, 96, 480, 10, 2, 33)
    assert timing.line == 1600 and timing.frame == 525
    await run(dut, timing, frames=1.02)


async def run_framebuffer(dut, timing: Timing, row_lines: int, frames: float,
                          seed: int = 2) -> int:
    """The image lives in SRAM with the program; the host sends nothing."""
    assert timing.v_visible % row_lines == 0
    await start_clock(dut, 20)
    await reset_top(dut)
    rng = random.Random(seed)
    rows = [[rng.randrange(256) for _ in range(timing.bytes_per_line)]
            for _ in range(timing.v_visible // row_lines)]
    rows[0] = [0xFF] * timing.bytes_per_line
    rows[-1] = [0xAA] * timing.bytes_per_line
    cell, cells, front, sync, back, _, v_front, v_sync, v_back = timing.args
    program = vga_framebuffer(cell, cells, front, sync, back, sum(rows, []), row_lines,
                              v_front, v_sync, v_back)
    await load_program(dut, program)
    await start_engine(dut)
    lines = [row for row in rows for _ in range(row_lines)]
    return await check(dut, timing, lines, frames)


@cocotb.test()
async def test_vga_framebuffer_small_frames(dut):
    """Frame buffer, small timing, three frames: each row on 3 lines, the
    rows in order, then the blank lines, and the same image again."""
    timing = Timing(4, 16, 6, 10, 8, 12, 2, 2, 3)
    assert timing.line >= 64
    assert await run_framebuffer(dut, timing, row_lines=3, frames=3) == 3 * timing.frame


@cocotb.test()
async def test_vga_framebuffer_single_lines(dut):
    """Frame buffer with one line a row (every row change path) and
    one-byte lines at the shortest line the program allows."""
    timing = Timing(4, 8, 10, 12, 10, 6, 1, 1, 1)
    assert timing.line == 64
    assert await run_framebuffer(dut, timing, row_lines=1, frames=3) == 3 * timing.frame


@cocotb.test()
async def test_vga_framebuffer_640x480(dut):
    """640 x 480 at 50 MHz from a 600-byte frame buffer (80 x 60 cells of
    8 x 8 pixels), one whole frame and into the next."""
    timing = Timing(16, 80, 32, 192, 96, 480, 10, 2, 33)
    await run_framebuffer(dut, timing, row_lines=8, frames=1.02)
