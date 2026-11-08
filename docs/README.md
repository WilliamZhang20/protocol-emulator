# Documentation: start here

This chip talks serial protocols (UART, SPI, I2C, USB, Ethernet and more)
on its pins. None of those protocols is built into the hardware. Each one
is a *configuration*: a small program loaded into on-chip memory tells
general-purpose hardware blocks how to behave.

## Reading order

Read these in order the first time. Each page is short.

1. [Overview](overview.md): what the chip is, its parts, and one example
   walked through end to end.
2. [Signal space](signal-space.md): how the parts are wired together.
3. [Tiles](tiles.md): the hardware blocks that do bit-level work.
4. [Contexts](contexts.md): how the hardware switches between two setups
   in one clock cycle.
5. [Byte layer](byte-layer.md): blocks that work on whole bytes and
   packets.
6. [Controller (PX8)](controller.md): the small processor that sets
   everything up.
7. [Host link](host-link.md): how a board's microcontroller loads programs
   and moves data.
8. [Protocols](protocols.md): every protocol that has been built and
   tested.
9. [Verification](verification.md): how the design is checked.
10. [Limits](limits.md): what does not work yet.

Other pages:

- [External hardware, pins and clocks](hardware.md)
- [Formal verification details](../formal/README.md)
- [Tiny Tapeout datasheet text](info.md)

## Glossary

| Term | Meaning |
| --- | --- |
| **Tile** | A hardware block with one job, such as a timer or a shifter. |
| **Fabric** | All the tiles together, plus the wiring between them. |
| **Line** | One wire in the shared [signal space](signal-space.md). There are 64. |
| **Configuration** | The register values that tell each tile what to do. |
| **Context** | One full set of configuration. Each tile holds two. |
| **Controller (PX8)** | The small processor that writes configurations and makes decisions. |
| **Host** | The microcontroller on the board that talks to this chip. |
| **FIFO** | A small queue that holds bytes between the host and the fabric. |
| **Frame** | One unit on the wire, for example a start bit, 8 data bits and a stop bit. |
| **Packet** | A group of bytes that belong together, for example one Ethernet frame. |
| **Tag** | Two extra bits that travel with a byte: *eop* (end of packet) and *err* (error). |
| **Cycle** | One tick of the chip's clock (20 ns at 50 MHz). |
