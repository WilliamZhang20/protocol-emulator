<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This chip speaks serial protocols on its pins, but none of them is built
into the hardware. Instead it has general-purpose blocks:

- 4 timers, 2 shifters and 2 counters;
- a CRC engine;
- 8 small logic cells and 8 pin drivers;
- 8 byte tiles for packet work: escaping, checksums, filtering.

A program in on-chip SRAM **connects** these blocks for one protocol,
through 64 shared wires, then steps aside. The connected blocks run every
clock cycle on their own, so the timing is exact. A tiny controller (PX8)
loads the setup and makes the step-by-step decisions, but it never drives
a pin or times a bit. Every block holds two setups, and can switch
between them in one step.

UART, SPI (master and slave), I2C (master and slave), PS/2 (device and
host), low-speed USB, 10BASE-T Ethernet, CAN 2.0A, JTAG, SWD, 1-Wire,
I2S, WS2812, DMX512, synchronous HDLC, async HDLC/PPP, SLIP, a 74HC595/165
GPIO expander, a quadrature decoder and VGA are all programs, each tested
against a model of the other end; eight are also formally proven on the
whole core. See [the documentation](README.md).

## How to test

Load a program and payload over the nibble host link on `ui_in`, start the
engine, and observe the protocol on `uio[7:0]`. Hold each host command and
each `8'h00` separator for at least 2 clocks. Each shifter has its own TX
and RX FIFO channel; host command `E` selects the one the FIFO commands
use. Run `make verify` for lint,
dead-logic detection, cocotb protocol tests, and formal checks.

## External hardware

All pins are 3.3 V digital and inputs are not 5 V tolerant. Default
protocol pins follow the Tiny Tapeout recommended pinouts:

- **UART:** `uio[1]` TXD, `uio[2]` RXD. Any 3.3 V USB-UART Pmod.
- **SPI:** `uio[0..3]` CS/MOSI/MISO/SCK. Direct to 3.3 V devices.
- **I2C:** `uio[2]` SCL, `uio[3]` SDA. Needs 2.2–4.7 kΩ pull-ups to 3.3 V.
- **PS/2:** `uio[4]` CLK, `uio[5]` DATA. Needs a 5 V ↔ 3.3 V
  bidirectional level shifter.
- **Low-speed USB:** `uio[4]` D+, `uio[5]` D−. Needs series resistors and a
  1.5 kΩ (device) or 15 kΩ (host) termination; a buffer helps on long
  cables.
- **10BASE-T:** `uio[6]` TD+, `uio[7]` TD− (send), `uio[4]` RD (receive).
  Needs a 40 MHz clock, a line driver, a resistor network, magnetics, and
  a receive comparator.

See [hardware.md](hardware.md) for clock choices, host-link timing, and
details.
