# Stage 5 protocol coverage experiment

The experimental chip top uses one heterogeneous 3×3 grid and the two SRAM
macros for all cases below. The compiler paths are **restricted source
profiles**, not general lowering of arbitrary `.spt` functions. They reject
source semantics they do not recognize. The chip tests use Tiny Tapeout pins
and host commands only; they do not access internal RTL hierarchy.

| Workload | Source / mapping | RTL pin evidence | Boundaries |
| --- | --- | --- | --- |
| SPI | Existing source-checked 12-bit component image and fixed frame scheduler | Serial transfer and SRAM capture in `test_memory_placement.py` | Not full source-function lowering. |
| UART | Existing source-checked independent TX/RX component image and fixed scheduler | Concurrent TX/RX and SRAM in `test_memory_placement.py` and grid regression | Not full source-function lowering. |
| I²C | `examples/i2c.spt` restricted `write_only` source profile; generic sequencer and routed contexts | START, address, data, ACK/NACK, stretch, STOP and RX SRAM in `test_temporal_i2c.py` | No reads, repeated starts or general runtime-variable source programs. |
| JTAG | Both JTAG example source tests are lowered to a static stream of paired TDI/TMS bytes; source expectations retain bit offsets. The generic temporal sequencer requests each paired-shifter frame. | TAP IDCODE and user-register write/read, including peer assertions, in `test_jtag_tap.py` | Literal `step`/`scan8` calls only; padding is emitted only in TAP idle and adds clocks. Not a general JTAG source compiler. TMS uses the multiplexed `uo[0]` output. |
| USB | `examples/usb.spt` restricted low-speed DATA0 transmit profile, with specialized payload of 0–8 data bytes. Uses coder, CRC, credit reader and temporal controller for EOP and output release. | Empty, mixed/stuffed and eight-byte packets; runtime SRAM payload changes, CRC, NRZI, per-bit timing, SE0/J EOP, bus release and repeated transmissions in `test_coded_stream.py` | Transmit subset only: no USB receive, enumeration, token packets or analog compliance. 50 MHz clock, 33 cycles/bit. |
| Ethernet | `WIRE_FRAME` from `examples/ethernet_tx_coded.spt`; coder and CRC emit a stored-frame fragment. | 60-byte frame, preamble and FCS checked at digital differential pins over two transmissions while the host also writes to SRAM0; 40 MHz clock, two cycles/half-bit | Source **frame fragment**, not the full `transmit()` session: link pulses, timed inter-frame behavior and analog PHY/magnetics are not implemented or verified. Outputs return to a quiet digital state after a frame. |

The JTAG compiler reports `peer_checks` for source assertions on the simulated
attached TAP. These are checked by the independent peer model; they are not
hardware read operations. The USB and Ethernet route descriptions are routed
by CIRCT and encoded against `architecture/grid_3x3.json`; the compiler also emits an ASCII route/resource map. They place the coded
shifter with the CRC in grid cell 8. The coded shifter's four control lines
share the four routed CRC selectors. Two additional local outputs expose its
serial signal and activity; the existing grid LUT can invert the signal.

The coded reader starts on the configured shift tick so its first bit receives
one full period. A byte request without a credited byte at a word boundary
terminates with an error rather than silently inserting an early CRC tail. The
separate `stream_coder` probe tests the existing two-credit reader and legacy
coder under registered responses, periodic contention and intentional
starvation. An RTL-only fault-injection bench also verifies that the actual
chip fabric reports an underrun, releases the USB bus, drains the reader and
restarts. These tests are not a proof that every legal
shared-bank traffic pattern meets every wire deadline. The source-specific USB
end sequence uses two routing contexts and the generic sequencer; a configurable
output-enable gate releases the bus after EOP. No protocol-specific USB state
machine is hardwired into the chip.

Reproduce the source profiles with the sibling compiler's
`circt_lab/test_i2c_temporal.sh`, `test_jtag_trace.sh` and
`test_coded_stream.sh`, each passed a built CIRCT mapper. Run `make lint
 grid-contract-check grid-sequencer-test grid-fabric-experiment
 grid-coded-abort-test` and the normal
cocotb regression for the RTL checks. The physical flow and its actual
post-layout gate tests remain separate from generic flattened Yosys simulation;
see current CI for their status. The previous stage 4 physical run failed
routing/layout checks, so no physical-fit or timing-closure claim is made.

A same-library flattened synthesis proxy after integrating the coded tile
measured 220,704.98 µm² of standard cells versus 198,308.78 µm² at stage 4
(+22,396.20 µm², +11.29%). Both exclude SRAM macros and physical overhead;
this is a cost comparison, not a fit verdict. The actual physical workflow must
establish placement, routing and timing.
