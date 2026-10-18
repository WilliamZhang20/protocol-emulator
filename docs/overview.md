# Overview

## The idea in one paragraph

Most programmable protocol chips use a processor that wiggles pins in
software. The timing of each bit then depends on how long the instructions
take. This chip works differently. A program first *connects* hardware
blocks together, then steps out of the way. The connected blocks run every
clock cycle on their own, so every bit comes out at exactly the right
time. Nothing is decided by software while a bit is on the wire.

This is called a **spatial** design: behavior comes from how blocks are
arranged and connected, not from a sequence of instructions over time.

## The parts

```text
   board microcontroller (the host)
                │  ui_in / uo_out pins
                ▼
          ┌───────────┐       ┌──────────────────────┐
          │ host link │──────▶│ SRAM, 1 KB           │  holds the program
          └───────────┘       └──────────┬───────────┘
            │       ▲                    ▼
   TX FIFOs │       │ RX FIFOs   ┌──────────────────┐
            ▼       │            │ controller (PX8) │  sets everything up
       ┌─────────────────┐       └────────┬─────────┘
       │   byte layer    │                │ writes configuration
       │ (8 byte tiles)  │                ▼
       └────────┬────────┘   ┌──────────────────────────────┐
                └───────────▶│          bit fabric          │
                             │ timers, shifters, counters,  │
                             │ CRC, logic cells, pin cells   │
                             └──────────────┬───────────────┘
                                            ▼
                                 uio[7:0] protocol pins
```

From the pins inwards:

1. **Bit fabric.** Hardware blocks called *tiles* that do bit-level work:
   - make bit clocks (timers);
   - turn bytes into bits and back (shifters);
   - count things (counters);
   - compute checksums (CRC);
   - do small bits of logic (logic cells);
   - drive the pins (pin cells).

   All of them share 64 wires, the [signal space](signal-space.md).
2. **Byte layer.** Blocks that work on whole bytes. They sit between the
   shifters and the FIFOs, and handle things like escape bytes, checksums
   and filtering packets. See [Byte layer](byte-layer.md).
3. **FIFOs.** Small queues (4 bytes each) between the chip and the host.
   There are two channels, one per shifter, each with a transmit (TX) and
   a receive (RX) queue.
4. **Controller (PX8).** A tiny processor that runs the program from SRAM.
   It writes the configuration, then waits for events and decides what
   happens next. It has no instructions to drive pins or to wait a fixed
   time. See [Controller](controller.md).
5. **Host link.** Lets the board's microcontroller load the program, start
   and stop the chip, and send or receive bytes. See [Host link](host-link.md).

## Example: sending one UART byte

UART sends a byte as a 0 (start bit), then 8 data bits, then a 1 (stop
bit), each bit lasting a fixed time.

1. **The host loads a program** into SRAM and starts the chip.
2. **The program configures the tiles:**
   - **timer 0** ticks once per bit time;
   - **shifter 0** sends "start bit, 8 data bits, stop bit", moving to the
     next bit on every tick of timer 0;
   - **pin cell 1** drives pin 1 from shifter 0's output.
3. **The program arms the fabric** (turns it on), then idles.
4. **The host pushes a byte** into TX FIFO 0.
5. **Shifter 0 takes the byte and sends it.** Every bit lasts exactly one
   timer period, because the timer and shifter are hardware.

The controller did nothing after step 3. That is the whole idea.

## What is in the chip

| Block | Count |
| --- | --- |
| Timers | 4 |
| Shifters | 2 |
| Counters | 2 |
| CRC engine | 1 |
| Logic cells (4-input lookup table + flip-flop) | 8 |
| Pin cells | 8 |
| Byte tiles | 8 |
| FIFO channels (TX + RX, 4 bytes each) | 2 |
| SRAM | 1 KB |

Next: [Signal space](signal-space.md).
