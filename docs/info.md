<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A spatial protocol engine. Instead of a CPU that times bits with
instructions, the chip contains a small fabric of generic hardware tiles
(4 timers, 2 shifters, 8 pin cells) connected by a registered 32-line event
bus. A protocol is a configuration: which events start, stop, shift and
sample each tile, and which tile drives each pin. Once configured, the fabric
runs every clock with cycle-exact timing. A tiny prefix-encoded controller
(PX8), executing from on-chip SRAM, writes the configuration and handles
transaction-level decisions such as I2C START/STOP and ACK checks.

UART (full duplex), SPI (all four modes) and I2C (with clock stretching) are
SRAM programs. There is no protocol-specific logic. See the
[architecture reference](architecture.md) for the tile registers, event map,
controller ISA and protocol mappings.

## How to test

Load a program and payload over the nibble host link on `ui_in`, start the
engine, and observe the protocol on `uio[7:0]`. Run `make verify` for lint,
dead-logic detection, cocotb protocol tests, and formal checks.

## External hardware

UART needs only a TX/RX connection. SPI and I2C need a target device or a
microcontroller or FPGA acting as one; I2C needs pull-up resistors on SCL
and SDA.
