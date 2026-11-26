# Coded shifter inventory (step 2.2)

What `fabric_shifter` (the coded shifter) does, measured against what the
protocol census needs from a line coder and serializer (patterns L line
code and P parity, plus the receive side of F, in
[PROTOCOL_CENSUS.md](PROTOCOL_CENSUS.md)).

## Census needs against the tile

| Need | Census users | Tile | Evidence |
|---|---|---|---|
| Parity generate | UART 8E1, PS/2, SWD, LIN PID, I3C | yes (frame [11:10] even/odd) | existing formal (`fabric_shifter` bmc) |
| Parity check (receive) | PS/2, SWD, LIN | yes: wrong parity tags the word err | existing formal (loopback model: err exactly when parity was injected); loopback tb |
| Bit stuffing, transmit | CAN TX, USB, HDLC | yes (N equal bits or N ones) | existing formal (`coder_bmc`, run never longer than N) |
| Destuffing, receive | CAN RX, USB RX, HDLC RX | yes: drops the stuff sample, flags a wrong one (status 4) | loopback (this step) |
| NRZI transmit / receive | USB | yes / yes | loopback (this step) |
| Manchester transmit | 10BASE-T, IR (RC5) | yes | existing formal (`manch_bmc`) |
| Manchester receive | 10BASE-T RX, RC5, DALI | **added in this step** (halves checked, violation = status 5) | loopback, violation flagged |
| HDLC flag / abort detect | HDLC RX | as a stuff error: with ones-stuffing N=5 a sixth 1 is not the expected stuffed 0 | loopback: a corrupted stuffed run is never accepted as a good word |
| CRC sequencing | CAN, USB, HDLC, Ethernet | yes (direct link to the CRC tile, tail, skip) | existing formal and pin tests (Ethernet, USB TX) |
| Bit-edge resync | CAN RX, USB RX, UART at drift | in the timer (step 2.1 resync) | pin test: UART at +/-6% |

## Bugs found by the receive loopback

- **Equal-bits stuffing with N=1 never ends.** The stuff bit starts the
  next run (CAN's rule), so after one bit another stuff bit is always
  due: the transmitter sends stuff bits forever and the frame never
  completes. Now refused by construction: `grid_core` does not configure
  with that coder word (N=1 is valid for runs of ones). Same for
  Manchester with NRZI, which the tile never defined.

## Receive loopback

`experiments/fabric_v2/coder_loopback_tb.sv` (run by `make
tile-fabric-v2-experiment`): a transmitting tile drives a receiving tile
over one line, 600 frames of random framing (1-16 bits, either order,
0-3 pre and post bits of either value, no/even/odd parity) and coding
(stuff N 1-6 of either kind, NRZI, Manchester), random words and tick
spacing. Every word arrives intact with no error tag. Negative cases: a
corrupted bit in a stuffed run, an inverted half of a Manchester bit and
an inverted parity bit are all flagged. Mutations of the tile (no
Manchester check, no half-bit sample, no stuff check) each fail it.

## Gaps left, and where they close

| Gap | Blocks | Closes in |
|---|---|---|
| The coded tile runs only in packet mode, and its receive outputs (byte, err tag, status) are not connected in `grid_core` | every receive-coded protocol on a lane | 2.4: the lane core owns a coded shifter with its receive path and readback |
| Lanes use the plain `fabric_v2_shift`, which has no parity | UART 8E1, PS/2, SWD, LIN on lanes | 2.4: the lane's serializer is the coded shifter |
| Duration from data (SENT nibbles, PWM bits) | SENT TX | 2.5: live writes of a lane's timer periods (the shadow is already in `grid_timer`) |
| USB end-of-packet (SE0: both lines low) | USB RX | a pin-level event (LUT of the two pin levels), not the coder |

## Checksums (step 2.3)

The CRC tile gained an additive mode (shape word 75 bit 8; bit 9 selects
two's complement): a bit-serial adder over words of the tile's width, fed
LSB first in wire order, so it sits behind the same absorb/data lines or
coder link as the polynomial mode. One's complement keeps the carry
across words (LIN classic and enhanced checksums, the Internet checksum);
two's complement drops it per word (modular sums such as the Modbus LRC
before negation). `value` and the residue check use the folded sum; emit
sends the complemented sum LSB first.

- `formal/fabric_crc` `add_prove`: unbounded (PDR) proof against a
  word-level model written the textbook way (add each byte, fold the carry
  immediately), with arbitrary absorb, data, emit and init every cycle;
  6 RTL mutations all caught (`fabric_crc-mutations`, in CI). The
  polynomial-mode proofs are unchanged.
- `experiments/fabric_v2/crc_additive_tb.sv`: 400 random sums at widths
  1-32 with edge-heavy words, residue match and mismatch, emitted bits,
  and a CRC-16 before and after to show polynomial mode is untouched.
- The fold never needs a second carry (a word sum leaves the register all
  ones with a carry only if it was already so, which init never starts):
  the tile test's mutation of that case changed nothing, so the case was
  removed and the argument recorded in the RTL.

Not covered by the tile: the coder link gives the CRC tile every frame bit
including start and stop bits, so a UART checksum on a lane needs the link
to carry data bits only. That is a lane-core wiring choice (2.4).
