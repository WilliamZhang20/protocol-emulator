"""Byte layer: tagged packets, byte stuffing, checksums, idle-gap framing,
address filtering and error tags, checked through the pins only.

None of these protocols has dedicated hardware: each is a configuration of
the bit fabric plus the byte tiles between the shifters and the FIFOs."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from cocotb_tests.common import reset_top, start_clock
from cocotb_tests.fabric import (
    HDLC_CODES, SLIP_CODES, Bus, drain_rx_tagged, load_program, pop_rx_tagged,
    push_packet, push_tx, select_channel, start_engine, tx_full,
)
from cocotb_tests.protocols import (
    MODBUS_DONE_PIN, UART_RX_PIN, UART_TX_PIN, idle_framed_receiver,
    uart_packet_bursts, uart_packet_link, uart_receiver,
)

BIT = 24


def stuffed(data: list[int], codes: tuple) -> list[int]:
    c0, m0, c1, m1, esc, _ = codes
    out = []
    for byte in data:
        out += [esc, m0] if byte == c0 else [esc, m1] if byte == c1 else [byte]
    return out


def checksum(data: list[int], xor: bool) -> int:
    if xor:
        value = 0
        for byte in data:
            value ^= byte
        return value
    return -sum(data) & 0xFF


def packet_entries(data: list[int], last_err: bool = False) -> list[tuple[int, bool, bool]]:
    return [(b, i == len(data) - 1, last_err and i == len(data) - 1)
            for i, b in enumerate(data)]


async def uart_listen(dut, bus: Bus, pin: int, count: int) -> list[int]:
    """Reference 8N1 receiver on a pin."""
    received = []
    for _ in range(count):
        while bus.level(pin):
            await RisingEdge(dut.clk)
        await ClockCycles(dut.clk, BIT // 2)
        value = 0
        for index in range(8):
            await ClockCycles(dut.clk, BIT)
            value |= bus.level(pin) << index
        await ClockCycles(dut.clk, BIT)
        assert bus.level(pin) == 1, "missing stop bit"
        received.append(value)
    return received


async def uart_send(dut, bus: Bus, data: list[int], *, parity: int | None = None,
                    stop: int = 1) -> None:
    for byte in data:
        bits = [0] + [(byte >> i) & 1 for i in range(8)]
        if parity is not None:
            bits.append(parity(byte) if callable(parity) else parity)
        bits.append(stop)
        for level in bits:
            bus.drive[UART_RX_PIN] = level
            await ClockCycles(dut.clk, BIT)
        if stop == 0:                                 # back to idle
            bus.drive[UART_RX_PIN] = 1
            await ClockCycles(dut.clk, 2 * BIT)


async def serve(dut, tx: list[tuple[int, bool]], rx_count: int,
                tx_channel: int = 0, rx_channel: int = 1,
                timeout_polls: int = 4000) -> list[tuple[int, bool, bool]]:
    """One host: push tagged TX bytes on one channel while draining tagged
    RX bytes from another, so neither FIFO stalls the link."""
    received: list[tuple[int, bool, bool]] = []
    pending = list(tx)
    await select_channel(dut, tx_channel)
    current = tx_channel
    for _ in range(timeout_polls):
        if pending and current == tx_channel and not await tx_full(dut):
            byte, eop = pending.pop(0)
            await push_tx(dut, byte, eop=eop)
            continue
        if current != rx_channel:
            await select_channel(dut, rx_channel)
            current = rx_channel
        entry = await pop_rx_tagged(dut)
        if entry is not None:
            received.append(entry)
            continue
        if len(received) == rx_count and not pending:
            return received
        if pending:
            await select_channel(dut, tx_channel)
            current = tx_channel
    raise AssertionError(f"received only {received}")


def host_bytes(packets: list[list[int]]) -> list[tuple[int, bool]]:
    return [(b, i == len(p) - 1) for p in packets for i, b in enumerate(p)]


async def stuffed_roundtrip(dut, codes: tuple, *, prepend: bool, xor: bool) -> None:
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    delim = codes[5]
    packets = [[0x01, delim, 0x55, codes[4]], [0x10, 0x20]]
    wire = []
    expected = []
    for data in packets:
        body = data + [checksum(data, xor)]
        wire += ([delim] if prepend else []) + stuffed(body, codes) + [delim]
        expected += packet_entries(body)
    await load_program(dut, uart_packet_link(BIT, codes, prepend=prepend, xor=xor))
    await start_engine(dut)
    listener = cocotb.start_soon(uart_listen(dut, bus, UART_TX_PIN, len(wire)))
    received = await serve(dut, host_bytes(packets), len(expected))
    assert await listener == wire
    assert received == expected


@cocotb.test()
async def test_hdlc_framing_roundtrip(dut):
    """Async HDLC (PPP-style) framing: 7E delimits, 7E/7D are sent as
    7D 5E / 7D 5D, and an add checksum follows each packet. Received back,
    the packet is unstuffed and checked; its last byte is tagged eop."""
    await stuffed_roundtrip(dut, HDLC_CODES, prepend=True, xor=False)


@cocotb.test()
async def test_slip_framing_roundtrip(dut):
    """SLIP (RFC 1055) on the same tiles, reconfigured: C0 ends a packet,
    C0/DB are sent as DB DC / DB DD, and an xor checksum follows."""
    await stuffed_roundtrip(dut, SLIP_CODES, prepend=False, xor=True)


@cocotb.test()
async def test_injected_error_is_detected(dut):
    """The controller sends two packets; the second asks for an injected
    error, so its checksum is wrong on the wire and the receiver tags it
    err. The clean packet passes."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    good, bad = [0x31, 0x32, 0x33], [0x41, 0x42]
    await load_program(dut, uart_packet_link(
        BIT, HDLC_CODES, prepend=False,
        program_packets=((good, False), (bad, True))))
    await start_engine(dut)
    wrong = checksum(bad, False) ^ 0xFF
    wire = stuffed(good + [checksum(good, False)], HDLC_CODES) + [0x7E]
    wire += stuffed(bad + [wrong], HDLC_CODES) + [0x7E]
    listener = cocotb.start_soon(uart_listen(dut, bus, UART_TX_PIN, len(wire)))
    expected = packet_entries(good + [checksum(good, False)])
    expected += packet_entries(bad + [wrong], last_err=True)
    received = await serve(dut, [], len(expected))
    assert await listener == wire
    assert received == expected


@cocotb.test()
async def test_idle_gap_framing_and_address_filter(dut):
    """Modbus-RTU style: packets are separated only by line idle time, and
    only those addressed to 0x11 reach the host. The controller raises a
    pin when the first matching packet arrives."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[UART_RX_PIN] = 1
    await load_program(dut, idle_framed_receiver(BIT, gap_bits=15, address=0x11))
    await start_engine(dut)
    await ClockCycles(dut.clk, 200)
    other, first, second = [0x22, 0x01, 0x02], [0x11, 0xAB, 0xCD], [0x11, 0x05]
    await uart_send(dut, bus, other)
    await ClockCycles(dut.clk, 30 * BIT)
    assert (int(dut.uio_out.value) >> MODBUS_DONE_PIN) & 1 == 0, "matched a foreign packet"
    await uart_send(dut, bus, first)
    await ClockCycles(dut.clk, 30 * BIT)
    assert (int(dut.uio_out.value) >> MODBUS_DONE_PIN) & 1 == 1, "match event missed"
    await uart_send(dut, bus, second)
    await ClockCycles(dut.clk, 30 * BIT)
    await select_channel(dut, 0)
    assert await drain_rx_tagged(dut) == packet_entries(first) + packet_entries(second)


@cocotb.test()
async def test_packet_tag_ends_tx_burst(dut):
    """Each host packet becomes one burst frame (start bit, bytes back to
    back, parity over the last byte, stop bit), ended by the packet's eop
    tag rather than by a word counter."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    packets = [[0xA7, 0x3C, 0x01], [0x55, 0x0F]]
    await load_program(dut, uart_packet_bursts(BIT))
    await start_engine(dut)

    async def sample() -> list[list[int]]:
        frames = []
        for data in packets:
            while bus.level(UART_TX_PIN):
                await RisingEdge(dut.clk)
            await ClockCycles(dut.clk, BIT // 2)
            bits = [bus.level(UART_TX_PIN)]
            for _ in range(8 * len(data) + 2):     # stop at mid stop bit,
                await ClockCycles(dut.clk, BIT)    # so a gapless next start
                bits.append(bus.level(UART_TX_PIN))  # bit is still ahead
            frames.append(bits)
        return frames

    sampler = cocotb.start_soon(sample())
    for data in packets:
        await push_packet(dut, data)
    expected = []
    for data in packets:
        bits = [0]
        for byte in data:
            bits += [(byte >> i) & 1 for i in range(8)]
        expected.append(bits + [bin(data[-1]).count("1") & 1, 1])
    assert await sampler == expected


@cocotb.test()
async def test_uart_framing_errors_are_tagged(dut):
    """8E1 receiver: a byte with a wrong parity bit and a byte with a wrong
    stop bit reach the host tagged err; a clean byte does not."""
    await start_clock(dut)
    await reset_top(dut)
    bus = Bus(dut)
    bus.drive[UART_RX_PIN] = 1
    await load_program(dut, uart_receiver(BIT, parity=1))
    await start_engine(dut)
    await ClockCycles(dut.clk, 200)

    def even(byte):
        return bin(byte).count("1") & 1

    await uart_send(dut, bus, [0x5A], parity=even)
    await uart_send(dut, bus, [0x5B], parity=lambda b: 1 - even(b))
    await uart_send(dut, bus, [0x33], parity=even, stop=0)
    await uart_send(dut, bus, [0x0F], parity=even)
    await ClockCycles(dut.clk, 4 * BIT)
    await select_channel(dut, 0)
    assert await drain_rx_tagged(dut) == [
        (0x5A, False, False), (0x5B, False, True),
        (0x33, False, True), (0x0F, False, False)]
