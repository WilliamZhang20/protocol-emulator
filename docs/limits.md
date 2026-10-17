# Limits

What the chip cannot do yet, and what is not yet measured.

## Protocol limits

- **Two streams at once.** There are two shifters, so at most two serial
  streams run at the same time.
- **Words up to 16 bits.** Longer fields need burst mode, which works in
  whole words.
- **Fast signals.** The fabric needs at least 2 clock cycles per half bit.
  10 Mb/s Ethernet already needs a 40 MHz clock.
- **Not built yet:** CAN, JTAG, SWD, 1-Wire, I2C slave mode, and PS/2
  sending to the device. The tiles should be able to express them, but
  that is not shown until they are tested.
- **Byte-level maths.** The controller can xor, and, and count, but has no
  add. Additive checksums go through the byte layer's `CHECK` tile.

## Hardware limits

- **SRAM is shared.** Program, configuration tables and data all live in
  the same 1 KB. A full-size Ethernet frame (1518 bytes) does not fit.
- **Contexts:** two per tile. A protocol with more phases than that still
  needs the controller to reload settings.

## Not yet measured

- **Timing:** each version is checked by the full chip flow (GDS) in CI.
  The newest changes (byte layer, contexts) have not yet been through that
  flow. CI gates on the typical corner; the slow corner (1.08 V, 125 °C)
  was 0.07 ns short on two paths before the latest timing fixes.
- **Area:** contexts and the byte layer together make the core about
  380k µm² in local synthesis. The real figure comes from the GDS run.

## Compared with an embedded FPGA

| | This chip | Embedded FPGA |
| --- | --- | --- |
| Building blocks | Big blocks (a whole timer or shifter) | Tiny lookup tables |
| Timing | Every configuration meets the clock checked once at tapeout | Needs its own place-and-route and timing check per design |
| Changing behaviour | A register write, even mid-transaction | Reload the whole bitstream |
| Flexibility | Less; glue cells cover small gaps | More |
