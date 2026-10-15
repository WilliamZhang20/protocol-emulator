<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A spatial protocol engine. Instead of a CPU that times bits with
instructions, the chip contains a fabric of generic hardware tiles: 4
timers, 2 shifters, 2 counters, a CRC engine, 8 LUT4+FF glue cells and 8 pin
cells, all connected through one 64-line signal space. A protocol is a
configuration: which lines start, stop, shift, sample and step each tile,
what each glue cell computes, and which line drives each pin. Once armed,
the fabric runs every clock with cycle-exact timing. A tiny prefix-encoded
controller (PX8), executing from on-chip SRAM, writes the configuration and
handles transaction-level decisions.

UART, SPI, I2C, PS/2, low-speed USB (transmit and receive) and 10BASE-T
transmit are SRAM programs; there is no protocol-specific logic. See the
[architecture reference](architecture.md).

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
- **10BASE-T transmit:** `uio[6]` TD+, `uio[7]` TD−. Needs a 40 MHz clock,
  a line driver, a resistor network, and magnetics.

See [hardware.md](hardware.md) for clock choices, host-link timing, and
details.
