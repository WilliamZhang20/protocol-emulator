"""Black-box RTL/GL test of one configurable SPI and UART chip interface."""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer


@cocotb.test()
async def spi_and_independent_uart_on_same_fabric(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    state = {'op': 0, 'strobe': 0, 'rx': 1}

    def drive():
        dut.uio_in.value = (state['op'] << 2) | (state['strobe'] << 1) | state['rx']

    drive()
    await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 8)

    async def command(op, data):
        await FallingEdge(dut.clk)
        dut.ui_in.value = data
        state['op'] = op; state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk)
        state['strobe'] = 1; drive()
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk)
        state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)

    async def idle_opcode(op):
        await FallingEdge(dut.clk)
        state['op'] = op; state['strobe'] = 0; drive()
        await ClockCycles(dut.clk, 4)

    async def config_word(index, word):
        await command(0, index)
        await command(6, word & 255)
        await command(7, word >> 8)

    async def load_image(name, *, tx_length=3, rx_capacity=5):
        words = [int(x, 16) for x in (Path(__file__).parents[1] / 'data' / name).read_text().splitlines()]
        assert len(words) == 27
        await command(4, 0)  # disarm
        assert int(dut.uio_oe.value) == 0
        await command(4, 11)  # config mode, host and actor both bank 1
        for index, word in enumerate(words):
            await config_word(index, word)
        await config_word(27, tx_length)
        await config_word(28, rx_capacity)
        await command(4, 3)  # leave config mode while disarmed
        await command(6, 100)  # source address, latched while disarmed
        await command(7, 200)  # RX region / SPI destination
        await command(4, 7)  # arm, both requesters on bank 1

    async def write_byte(addr, value):
        await command(0, addr & 255)
        await command(1, addr >> 8)
        await command(2, value)

    async def read_byte(addr):
        await command(0, addr & 255)
        await command(1, addr >> 8)
        await command(3, 0)
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk)
        return int(dut.uo_out.value)

    async def spi_peer(alternate=False):
        observed = 0; samples = 0; previous = 0
        for _ in range(600):
            await FallingEdge(dut.clk); await Timer(1, unit='ns')
            pins = int(dut.uio_out.value); sck = (pins >> 5) & 1
            if sck and not previous:
                if state['op'] == 7 and state['strobe'] == 0:
                    assert int(dut.uo_out.value) == 0, 'CS must be asserted during SPI'
                observed = (observed << 1) | ((pins >> 6) & 1)
                samples += 1
            previous = sck
            if pins & 0x80:
                assert samples == 12 and observed == (0 if alternate else 0xA5C)
                return
        assert False, 'SPI did not complete'

    async def receive_uart(values, bit_cycles=64):
        for value in values:
            await FallingEdge(dut.clk); state['rx'] = 0; drive()
            await ClockCycles(dut.clk, bit_cycles)
            for bit in range(8):
                await FallingEdge(dut.clk); state['rx'] = (value >> bit) & 1; drive()
                await ClockCycles(dut.clk, bit_cycles)
            await FallingEdge(dut.clk); state['rx'] = 1; drive()
            await ClockCycles(dut.clk, bit_cycles)

    async def check_uart_tx(values, bit_cycles=64):
        previous = 1
        for value in values:
            for _ in range(2500):
                await FallingEdge(dut.clk); await Timer(1, unit='ns')
                current = (int(dut.uio_out.value) >> 6) & 1
                if previous and not current:
                    break
                previous = current
            else:
                assert False, 'UART start bit not observed'
            await ClockCycles(dut.clk, bit_cycles // 2)
            assert ((int(dut.uio_out.value) >> 6) & 1) == 0
            for bit in range(8):
                await ClockCycles(dut.clk, bit_cycles)
                assert ((int(dut.uio_out.value) >> 6) & 1) == ((value >> bit) & 1), (value, bit)
            await ClockCycles(dut.clk, bit_cycles)
            assert ((int(dut.uio_out.value) >> 6) & 1) == 1, 'UART stop bit'
            previous = 1

    await load_image('v2-unified-spi.mem')
    assert int(dut.uio_oe.value) == 0xE0
    await command(4, 0); await command(4, 11); await config_word(21, 31)
    await command(4, 3); await command(4, 7)
    assert int(dut.uio_oe.value) == 0, 'invalid selector must keep pins disabled'
    await command(4, 0); await command(4, 11); await config_word(21, 9)
    await command(4, 3); await command(4, 7)
    assert int(dut.uio_oe.value) == 0xE0
    await write_byte(7, 0xA2)
    await command(4, 0); await command(4, 0); await command(4, 4)
    await write_byte(7, 0x31)
    await command(4, 0); await command(4, 3); await command(4, 7)
    assert await read_byte(7) == 0xA2
    await write_byte(100, 0x0A); await write_byte(101, 0x5C)
    peer = cocotb.start_soon(spi_peer())
    await command(5, 0); await idle_opcode(7); await peer
    assert await read_byte(200) == 0x0F and await read_byte(201) == 0xFF

    # Reconfigure an output selector and repeat the SRAM-backed transfer.
    await command(4, 0); await command(4, 11); await config_word(20, 0)
    await command(4, 3); await command(4, 7)
    peer = cocotb.start_soon(spi_peer(alternate=True))
    await command(5, 0); await idle_opcode(7); await peer

    await load_image('v2-unified-uart.mem')
    assert int(dut.uio_oe.value) == 0xC0
    for addr, value in [(100, 0x53), (101, 0xA6), (102, 0x19), (205, 0xC7)]:
        await write_byte(addr, value)

    # The receiver must run with no host TX command.
    await receive_uart([0x12, 0xA5, 0x7E])
    await ClockCycles(dut.clk, 30)
    for addr, value in [(200, 0x12), (201, 0xA5), (202, 0x7E)]:
        assert await read_byte(addr) == value

    # A TX stream runs while independent RX traffic fills the remaining two
    # slots. The third RX byte must set overflow without overwriting the sentinel.
    tx_peer = cocotb.start_soon(check_uart_tx([0x53, 0xA6, 0x19]))
    rx_peer = cocotb.start_soon(receive_uart([0x44, 0x81, 0xFE]))
    await command(5, 0)
    # Host and serial actor use the same bank during this access.
    await write_byte(20, 0x69)
    assert await read_byte(20) == 0x69
    await tx_peer; await rx_peer
    await ClockCycles(dut.clk, 80)
    assert await read_byte(203) == 0x44 and await read_byte(204) == 0x81
    assert await read_byte(205) == 0xC7
    await idle_opcode(4); await Timer(1, unit='ns')
    assert int(dut.uo_out.value) & 0x80, 'RX overflow must be sticky'
    await command(4, 0)
    assert int(dut.uio_oe.value) == 0
