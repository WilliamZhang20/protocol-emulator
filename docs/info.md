<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The project is an SRAM-programmed, cycle-deterministic protocol engine. A
host loads a bytecode program through `ui_in`, exchanges payload bytes
through TX and RX FIFOs, and starts the engine. A small control CPU runs the
program and launches regions on two real-time action lanes, which drive and
sample the `uio` pins one action per clock. UART, SPI, I²C, JTAG, 1-Wire, and
low-speed USB line patterns are all programs; there is no protocol-specific
hardware.

The [architecture and programming reference](architecture.md) describes the
host commands, instruction set, lane actions, and timing.

## How to test

The host link is a nibble command protocol on `ui_in`: drive one command
byte for a clock, then `0x00`. Load a program with commands `1`-`5`, start
it with `0x81`, and poll status with `0xA0` on `uo_out`.

`make verify` runs lint, the SRAM model test, the cocotb regression, and
formal checks. The UART tests load TX and RX programs through `ui_in`, run
them from SRAM, and check 8-N-1 frames on `uio[0]`. The clocked-region tests
run SPI modes 0 and 3 and an I²C write with ACK and clock stretching on the
same engine.

## External hardware

Loopback demonstrations need only pin connections. Paired tests can use a
microcontroller, FPGA, or protocol analyzer.

The soft low-speed USB demo (not USB-compliant) uses `uio[0]`/`uio[1]` as
D+/D−, with a 1.5 kΩ pull-up from D− to 3.3 V and series resistors on both
lines.
