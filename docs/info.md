<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The project is an SRAM-programmed deterministic protocol engine. Programs use
shared timing, shifting, FIFO, and configurable GPIO resources to implement
protocols without dedicated UART, SPI, or I2C state machines.

See the [high-level architecture plan](architecture.md) for the component
structure, reprogrammability model, initial demonstrations, and growth path.

## How to test

The first milestone will load protocol programs through the host interface and
demonstrate UART, SPI, and I2C through loopback or paired endpoints.

## External hardware

The basic loopback demonstrations require only suitable pin connections. Paired
endpoint tests may use a microcontroller, FPGA, or protocol analyzer.
