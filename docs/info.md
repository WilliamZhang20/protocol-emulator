<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The project is an SRAM-programmed deterministic protocol engine. Programs use
shared timing, shifting, FIFO, CRC, and configurable GPIO resources to
implement protocols without dedicated UART, SPI, or I2C state machines. The
architecture locks a reusable CPU baseline and migrates specialized helpers
toward a programmable action engine (see architecture.md).

See the [architecture and programming reference](architecture.md) for the host
commands, bytecode, component structure, roadmap (Phases A–D), and
reprogrammability model.

## How to test

Run `make verify` for lint, foundry SRAM compilation/testing, cocotb, and formal
checks. The UART tests load separate TX and RX programs through `ui_in`, execute
them from SRAM, and observe an 8-N-1 frame through `uio[0]`. The bit-transfer
tests exercise the same autonomous engine for SPI mode 0/3 and I²C write/ACK
with clock stretching.

## External hardware

The basic loopback demonstrations require only suitable pin connections. Paired
endpoint tests may use a microcontroller, FPGA, or protocol analyzer.

Soft low-speed USB demos (non-compliant) use two `uio` pins as D+/D−. For an LS
device idle-J, add a 1.5 kΩ pull-up from D− to 3.3 V and series resistors on
both lines; do not expect USB-IF compliance without a real PHY.
