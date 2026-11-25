# Stage 5 protocol coverage experiment

The experimental chip top uses one heterogeneous 5×3 grid and the two SRAM
macros for all cases below. Rows 0–2 are the original grid; every earlier
image is unchanged and leaves rows 3–4 at their reset (inert) configuration. The compiler paths are **restricted source
profiles**, not general lowering of arbitrary `.spt` functions. They reject
source semantics they do not recognize.

**Generic compiled-program runner.** `test/cocotb_tests/test_compiled.py` runs
any compiled program from `test/data/compiled/`: the backend's image, its
program record (whose `interface` maps source pins to chip pins and says how
call arguments become SRAM bytes and host words) and the source's test plan
from `spatial test-plan`. It knows no protocol: it replays the source's own
`test` blocks through the host link, with the compiler's specification-written
peers (`test/peers`, vendored from the compiler's `sim/peers`), and checks every
`always` invariant each cycle. Set `COMPILED=path/NAME` to run another program. The chip tests use Tiny Tapeout pins
and host commands only; they do not access internal RTL hierarchy.

| Workload | Source / mapping | RTL pin evidence | Boundaries |
| --- | --- | --- | --- |
| SPI | The whole exported `transfer()` of `examples/spi.spt` (`spi.transfer`): `HALF` is a parameter and the body is compiled statement by statement into 8 sequencer rows. The source's `selected` and `cs_n` registers map to two registered LUT4 cells; `sck_clock`, `cs_off` and `gap` to timers 0–2; `bits` to shifter 0. The source's word counter is lowered to the sequencer's per-word frame loop. The older 12-bit component image remains as a regression. | The source file's own tests (`exchanges bytes with a device`, `back-to-back transactions`) and its `always` invariant, run by the generic compiled-program runner (`test_compiled.py`) with the specification-written `spi_device` peer. A mutated image (CS register never set) fails. | One SRAM byte per word: SCK pauses between words (no edges while paused). CS is on the multiplexed `uo[0]`. |
| UART | `examples/uart.spt` exports only streams. The existing source-checked grid image runs `send` through the stream reader and frame scheduler and `recv` through autonomous RX into SRAM; the backend now reports this interface. | The source file's own tests (`loopback` over a wire, `talks to a terminal` with the `uart_device` peer, which referees bit timing and stop bits) in `test_compiled.py`; concurrent TX/RX and overflow in `test_memory_placement.py`. | No temporal program is needed: the source has no function body. The host sees RX progress as a byte count on idle opcode 5. |
| I²C | The whole exported `write_read()` of `examples/i2c.spt` (`i2c.write_read`, 16 sequencer rows): START, repeated START and STOP follow the source's `condition()` patterns one HALF slot at a time; each `write()`/`read()` is a frame from SRAM; shifter 1 and a registered LUT4 latch carry a per-frame tag that marks the frame before `restart()`. The original `write_only` profile remains as a regression. | All five source tests in `test_compiled.py` with the `i2c_target` peer: register read with repeated START, 8-byte payload, empty payload, NACK from an absent device (`fails "nack"`) then a successful retry, and a 600-cycle clock-stretching device. Disabling the tag latch fails four of the five. `write_only` (with stretch and NACK) in `test_temporal_i2c.py`. | The compiled subset must end with `read(last: 1)` then `stop()`; writes after a read and `restart()` after a read are rejected. |
| JTAG | Both JTAG example source tests are lowered to a static stream of paired TDI/TMS bytes; source expectations retain bit offsets. The generic temporal sequencer requests each paired-shifter frame. | TAP IDCODE and user-register write/read, including peer assertions, in `test_jtag_tap.py` | Literal `step`/`scan8` calls only; padding is emitted only in TAP idle and adds clocks. Not a general JTAG source compiler. TMS uses the multiplexed `uo[0]` output. |
| USB | `examples/usb.spt` restricted low-speed DATA0 transmit profile, with specialized payload of 0–8 data bytes. Uses coder, CRC, credit reader and temporal controller for EOP and output release. | Empty, mixed/stuffed and eight-byte packets; runtime SRAM payload changes, CRC, NRZI, per-bit timing, SE0/J EOP, bus release and repeated transmissions in `test_coded_stream.py` | Transmit subset only: no USB receive, enumeration, token packets or analog compliance. 50 MHz clock, 33 cycles/bit. |
| Ethernet | `WIRE_FRAME` from `examples/ethernet_tx_coded.spt`; coder and CRC emit a stored-frame fragment. | 60-byte and full-MTU frames, preamble and FCS checked at digital differential pins; full-MTU payload crosses the SRAM bank boundary. Host writes contend with SRAM0; 40 MHz clock, two cycles/half-bit | Source **frame fragment**, not the full `transmit()` session: link pulses, timed inter-frame behavior and analog PHY/magnetics are not implemented or verified. Outputs return to a quiet digital state after a frame. |
| Ethernet link session | The whole exported `transmit()` of `examples/ethernet_tx_coded.spt` (`ethernet_session` mode): declarations must match the profile exactly, `NLP_TICK` and the frame are parameters, and the body is compiled statement by statement into 15 sequencer rows. Uses only generic tiles: timers 0–3 (cadence, half-bit, pulse, tail), shifter 0 as a 10-tick counter, four registered LUT4 cells (idle-high, positive, negative, tail window) and the sequencer's routed event inputs. | `test_ethernet_session.py`: an observer independent of the configuration checks 4-clock (1,0) link pulses exactly 10×NLP_TICK apart (across the frame and across back-to-back sessions), Manchester data, CRC32 and exactly 12 clocks of TP_IDL. Real-time 16 ms period at 40 MHz (RTL) and NLP_TICK=4000 (RTL and gate level). A mutation that lengthens TP_IDL by one clock is rejected. | Digital transmit waveforms only: no analog PHY/magnetics, receive, collision handling or auto-negotiation. Sessions must send one frame between link pulses; the compiler rejects pulses while `sending` is set, unequal cadence counts and missing tail waits. |

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
shared-bank traffic pattern meets every wire deadline. For the tested same-bank
case, a three-client round robin has at most a three-cycle grant wait and the
registered return adds a cycle. With a 32-cycle minimum Ethernet byte period,
`ceil(4 / 32) + 1 = 2` gives the depth-two starting bound; USB has more slack.
That bound assumes continuous requests, same-bank ordered returns and no
additional routed latency. Cross-bank drains or new pipelines need a fresh bound; the full-MTU RTL test exercises the existing crossing but does not prove a worst-case bound. The source-specific USB
end sequence uses two routing contexts and the generic sequencer; a configurable
output-enable gate releases the bus after EOP. No protocol-specific USB state
machine is hardwired into the chip.

Reproduce the source profiles with the sibling compiler's
`circt_lab/test_i2c_temporal.sh`, `test_jtag_trace.sh`,
`test_coded_stream.sh` and `test_temporal_functions.sh`, each passed a built
CIRCT mapper. Run `make lint
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
