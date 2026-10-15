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
engine, and observe the protocol on `uio[7:0]`. Run `make verify` for lint,
dead-logic detection, cocotb protocol tests, and formal checks.

## External hardware

UART needs only a TX/RX connection. SPI and I2C need a target device or a
microcontroller or FPGA acting as one; I2C needs pull-up resistors on SCL
and SDA. Low-speed USB needs series resistors and a 1.5 kΩ pull-up as for
any bit-banged LS device. 10BASE-T transmit needs a 40 MHz clock and a
resistor network plus pulse transformer on TD±.
