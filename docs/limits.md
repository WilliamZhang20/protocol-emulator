# Limits

What the chip cannot do yet, and what is not yet measured.

## Protocol limits

- **Two streams at once.** There are two shifters, so at most two serial
  streams run at the same time.
- **Words up to 16 bits.** Longer fields need burst mode, which works in
  whole words.
- **Fast signals.** The fabric needs at least 2 clock cycles per half bit.
  10 Mb/s Ethernet already needs a 40 MHz clock.
- **Reaction time.** An input edge reaches an output in about 5 to 8
  cycles: 2 for the synchronizer, 1 for the pulse register, 1 per logic
  cell and 1 for the pin register. Consequences: an SPI slave runs at up
  to about clk / 16. A CAN node needs 8 cycles between the sample point
  and the end of the bit to place its ACK, which allows up to about
  1.25 Mb/s at 40 MHz.
- **Controller decisions.** The I2C slave compares its address on the
  controller in about 20 cycles, while SCL is high after the 8th bit.
  That covers standard mode (4 us) but not fast mode (0.6 us).
- **Feeding the FIFO.** Some protocols need their bytes to arrive in
  time. The SPI master pauses SCK between bytes and WS2812 lengthens a
  low time, both legal. A CAN frame, an I2S stream or a DMX512 packet
  that runs dry instead ends early. The host or the controller (streaming
  from SRAM at 11 cycles a byte) has to keep ahead.
- **CAN bus integration.** The receiver node takes the first edge after
  arming as a start of frame. Joining a bus in the middle of someone
  else's frame gives one bad packet; the CAN rule of waiting for 11
  recessive bits needs a logic cell the node does not have left.
- **Resources.** The CAN receiver uses all 8 logic cells, all 4 timers,
  both shifters and counters, and the CRC. Counters are 8-bit and only
  count up, which rules out fabric-only quadrature decoding and VGA line
  counting.
- **Byte-level maths.** The controller can xor, and, and count, but has no
  add. Additive checksums go through the byte layer's `CHECK` tile.

## Hardware limits

- **SRAM is shared.** Program, configuration tables and data all live in
  the same 1 KB. A full-size Ethernet frame (1518 bytes) does not fit.
- **Contexts:** two per tile. A protocol with more phases than that still
  needs the controller to reload settings.

## Not yet measured

- **Timing and area** of the registered signal space (every line a
  register output) come from the next GDS run. In local synthesis the core
  is about 415k µm². The run before it (`d48031f`) had −3.68 ns slack at
  the slow corner and 560k µm² after place and route, at 67.5 %
  utilization.

## Compared with an embedded FPGA

| | This chip | Embedded FPGA |
| --- | --- | --- |
| Building blocks | Big blocks (a whole timer or shifter) | Tiny lookup tables |
| Timing | Every configuration meets the clock checked once at tapeout | Needs its own place-and-route and timing check per design |
| Changing behaviour | A register write, even mid-transaction | Reload the whole bitstream |
| Flexibility | Less; logic cells cover small gaps | More |
