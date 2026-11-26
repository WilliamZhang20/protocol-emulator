# Protocol mapping census (2026-11-26)

What protocols need, what the 5 × 3 grid provides, and what a general
compiler and a protocol CGRA must add so that **held-out protocols** (written
from a specification, never seen while designing) compile and run without
hand-written images. The data and counts come from
[`protocol_census.py`](protocol_census.py); run it to regenerate them.

## Method

Vaughn Betz's research flow (ICCAD 2026 keynote, see NEXT_STEPS.md) gives the
method: an architecture file, a benchmark corpus, a retargetable compiler,
and measurement of where spatial hardware wins. The target is a
**coarse-grained reconfigurable architecture (CGRA) for event-driven,
stateful, temporally constrained protocol patterns**: its processing elements
(PEs) are protocol patterns, not LUTs or ALUs, and its control is per-lane
descriptor sequencing over a registered event network.

Corpus: the 22 pin-tested protocols of the earlier `arch/spatial` fabric
(PX8 control loop plus tiles, `test/cocotb_tests/test_*.py`, from `02d0933`
on), and 14 further protocol classes chosen from public specifications as a
stand-in for held-out protocols. The held-out oracle
(`protocol-emulator-oracle`) is deliberately not read; nothing here is tuned
to it.

Status categories, judged from the grid RTL at `f093ade`:

- **runs at pins**: a compiled or source-profile image passes pin-level tests today.
- **workaround**: works only with the host doing protocol work (parity, checksum)
  or the multiplexed `uo[0]` output standing in for a pad.
- **mappable (compiler only)**: every pattern has a grid resource; what is
  missing is general lowering. This is an engineering judgement until each
  one compiles and passes; treat it as a hypothesis.
- **blocked**: a needed pattern has no grid resource.

## A protocol is a composition of a small pattern vocabulary

Protocols are communicating extended state machines with timing over
dataflow of fields. Across the corpus they reduce to these patterns
(letters used in the tables):

| Pattern | Examples | Grid resource today |
|---|---|---|
| T timed waveform | bit clocks, phases, break, gaps, carrier | 4 timers (16-bit first/period, start/stop/hold) |
| S sample/sync | peer clock edge, start-edge hard sync | pin synchronizer + edge events, shifter sample input |
| F serialize field | width 1-16, bit order, constant bits | 2 shifters + frame engine (format/ormask) |
| L line code | NRZI, Manchester, bit stuffing, pulse-width bits | coded shifter (transmit), LUT4 cells |
| C check | CRC-5..32 | one CRC tile |
| P parity | UART 8E1, PS/2, SWD, LIN PID, I3C | **none** in the frame engine |
| K count/state variable | up/down count, DATA0/1 toggle, retries | 4 registered LUT4 cells; timers count when `hold` gates them |
| M match value | address, PID, command, flag 0x7E, SYNC | **none**: a branch sees only received bit 0 |
| Q sequence/branch | transaction control | 2 lane sequencers (16 rows, descriptors, paging) |
| R respond in window | ACK slot, target reply, turnaround | sequencer latency; needs M to decide what to send |
| A arbitrate | CAN, multi-master I2C | LUT XOR of TX and RX, abort |
| B peer clock stretch | I2C, SMBus | timer `hold` |
| X measure interval/timeout | idle gap, autobaud, pulse-distance decode | timer restart + level sample; **no capture** |
| Y full duplex | UART | two shifters, reader + writer |
| D host stream | every protocol | SRAM reader/writer streams, host link |

Use across all 36: host stream 36, serialize 29, timed waveform 27,
sample/sync 20, sequence/branch 20, CRC 12, line code 10, **match 9**,
respond-in-window 7, parity 6, measure 5, count 4, stretch 3, arbitrate 2,
full duplex 1.

## Census: the 22 inherited protocols

| Protocol | Pins out/in/bidir | Patterns | Grid today | Missing hardware | Note |
|---|---|---|---|---|---|
| UART 8N1 | 1/1/0 | T S F Y D | runs at pins | - | compiled uart.spt streams |
| SPI controller | 3/1/0 | T S F Q D | workaround | pins | CS on multiplexed uo[0] |
| SPI target | 1/3/0 | S F M Q R D | **blocked** | pins, match | input clock, command decode, MISO before next edge |
| I2C controller | 0/0/2 | T S F Q B D | runs at pins | - | write_read, NACK, stretch |
| I2C target | 0/0/2 | S F M Q R D | **blocked** | match | 7-bit address match, ACK in window |
| JTAG TAP | 3/1/0 | T S F Q D | workaround | pins | TMS on multiplexed uo[0] |
| SWD host | 1/0/1 | T S F P M Q R D | **blocked** | parity, match | 33-bit data+parity, 3-bit ACK, turnaround |
| PS/2 device RX | 0/2/0 | S F P D | workaround | parity | host checks odd parity |
| PS/2 host | 0/0/2 | T S F P Q R D | workaround | parity | host packs parity; RTS hold |
| 1-Wire master | 0/0/1 | T S Q D | mappable (compiler only) | - | timed slots; ROM search via host |
| WS2812 | 1/0/0 | T L D | mappable (compiler only) | - | bit selects high time: 2 timers + LUT |
| DMX512 | 1/0/0 | T F D | mappable (compiler only) | - | break/MAB + 8N2 |
| CAN TX | 1/1/0 | T F L C A Q D | mappable (compiler only) | - | coder stuffing, CRC-15, arbitration via LUT xor |
| CAN RX | 1/1/0 | S F L C M R Q D | **blocked** | rxcode, match | resync, destuff, CRC check, ACK slot |
| HDLC (sync) | 1/2/0 | S F L C M D | **blocked** | rxcode, match | flag 0x7E detect, zero-destuff, CRC-16 |
| I2S TX | 3/0/0 | T F D | workaround | pins | BCLK, WS, SD: third on uo[0] |
| USB LS TX | 0/0/2 | T F L C Q D | runs at pins | - | coded stream, NRZI, stuffing, CRC16, EOP |
| USB LS RX | 0/0/2 | S F L C M R Q D | **blocked** | rxcode, match | clock recovery, SYNC/PID match, handshake window |
| 10BASE-T TX | 2/0/0 | T F L C Q D | runs at pins | - | session: NLP, Manchester, FCS, TP_IDL |
| Quadrature | 0/2/0 | S Q K D | mappable (compiler only) | - | 4-state FSM in LUTs; host keeps count |
| VGA | 3/0/0 | T K D | workaround | pins | hsync, vsync, 1-bit colour; third on uo[0] |
| GPIO expander | 4/1/0 | T F D | **blocked** | pins | 74HC595 + 74HC165 chain |

## Census: 14 held-out protocol classes

| Protocol | Pins out/in/bidir | Patterns | Grid today | Missing hardware | Note |
|---|---|---|---|---|---|
| MDIO | 1/0/1 | T F Q D | mappable (compiler only) | - | two 16-bit frames, turnaround |
| Modbus RTU master | 1/1/0 | T F C X D | mappable (compiler only) | - | CRC-16 tile; 3.5-char gap by timer restart |
| Modbus RTU slave | 1/1/0 | T F C X M R D | **blocked** | match | address match, reply window |
| LIN master | 1/1/0 | T F P K D | workaround | parity, checksum | PID parity, additive checksum by host |
| LIN slave | 1/1/0 | S F P K X M D | **blocked** | capture, match, checksum | autobaud on 0x55, PID match |
| SMBus + PEC | 0/0/2 | T S F C Q B X D | mappable (compiler only) | - | I2C + CRC-8 tile + timeout |
| SD card (SPI mode) | 3/1/0 | T S F C M Q D | **blocked** | pins, match | CRC7, poll R1 != 0xFF, token 0xFE |
| NEC IR TX | 1/0/0 | T L D | mappable (compiler only) | - | 38 kHz carrier AND burst, pulse distance |
| NEC IR RX | 0/1/0 | S X F D | mappable (compiler only) | - | timer level sampled at edge = bit |
| SENT TX | 1/0/0 | T L C D | **blocked** | duration | nibble = 12..27 ticks: duration from data |
| Wiegand | 2/0/0 | T Q D | mappable (compiler only) | - | bit selects D0/D1 pulse: LUT |
| MIDI | 1/1/0 | T S F D | mappable (compiler only) | - | UART at 31250 |
| CAN FD TX | 1/1/0 | T F L C A Q D | **blocked** | paramctx | bit-rate switch mid-frame |
| I3C SDR controller | 0/0/2 | T S F P Q B D | **blocked** | paramctx, parity | push-pull/open-drain switch, T-bit |

## Totals

| Set | Runs | Workaround | Mappable (compiler only) | Blocked |
|---|---|---|---|---|
| Inherited (22) | 4 | 6 | 5 | 7 |
| Held-out classes (14) | 0 | 1 | 7 | 6 |
| All (36) | 4 | 7 | 12 | 13 |

Missing hardware, by protocols it blocks (workarounds in brackets):
**match 9**, pins 3 (4), receive line decode 3, parity 2 (3), parameter
contexts 2, capture 1, duration-from-data 1, checksum 1 (1). Match is the sole
blocker for 2 and co-blocks 7 more with receive decode, pins, parity or
capture.

## Findings

1. **The compiler is the largest single gap.** 12 protocols need no new
   hardware, and zero protocols compile from general source on the grid
   today: every running image comes from a restricted, per-protocol lowering
   (`circt_lab/*.inc`). A held-out protocol cannot run until lowering is
   general.
2. **The grid lost the "extended" half of the state machine, and with it
   the PX8 thesis.** The PX8 lineage's thesis was that tiles time every bit
   while a tiny controller only decides and never drives a pin or times a
   bit; it made data-dependent decisions and kept state variables in its
   registers (`XRC`/`JZ` compare, `DJNZ` counter, pointer), and covered all
   22 inherited protocols plus PPP and SLIP. The grid's sequencer has no data
   path, so anything that must decide on a received value is blocked. Either
   a PX8-class data-capable controller per lane or a spatial match PE
   (masked compare beside the shifter) restores it; the controller covers
   match, count and state at once, the match PE is faster for
   respond-in-window. Decided (NEXT_STEPS.md): a PX8 controller per lane, measured at
   11.4k um2 against 25.9k um2 for a row sequencer.
3. **Pins are the next limit.** The host link occupies uio[4:0], leaving two
   bidirectional pads, one input and a multiplexed `uo[0]`. 4-wire protocols
   run only through the multiplexed output, and target-side or chain protocols
   are blocked.
4. **Receive is weaker than transmit.** The coded shifter's receive path
   (destuff, NRZI/Manchester decode) is instantiated but not connected in
   `grid_core`, so USB, CAN and HDLC receive are blocked.
5. **Cheap completeness fixes:** frame-engine parity, an additive checksum
   mode in the CRC tile, timer capture, and duration-from-data in the timer
   each cost little area and remove 1-3 protocols' blocks or workarounds.
6. **Concurrency is not a coverage limit.** Only full-duplex UART needs two
   engines at once, and it runs. A second lane datapath matters for running
   two protocols at once, not for how many protocols map.
7. **Events must be latched for general lowering.** A row tests one event per
   clock, so a pulse on another event is lost. Hand lowerings avoid this by
   construction; a general compiler needs sticky event bits (set by the
   event, cleared on row entry) so correctness never depends on timing it
   cannot see.

## The protocol CGRA this implies

Processing elements, each a protocol pattern, joined by a registered 1-bit
event network and short word paths:

| PE | Patterns | Change from today |
|---|---|---|
| Timer | T, B, X, K | add capture of elapsed count on an event; period from a stream byte |
| Serializer | F, S, P, Y | add parity generate/check in the frame engine |
| Line coder | L | connect the receive decode path and edge resync |
| Check | C | add an additive checksum mode |
| **Match** (new) | M, R | masked compare of received word against 2-4 constants, events per hit; or folded into a PX8-class lane controller |
| State | K | registered LUT4 cells as today |
| Lane control | Q, R, A, K, M | per-lane controller that decides but never times a bit (the PX8 thesis): data-capable (compare, count, pointer), latched events, per-lane contexts (routing and tile parameters); descriptor rows where cheaper |
| Stream | D | reader/writer per lane |
| I/O | pins | uniform edge I/O tile; more pads once the host link moves |

Each source construct then has exactly one lowering target, which is what
makes a general compiler possible: `timer` → timer PE, `shifter` frame →
serializer (+ line coder), `crc` → check, `if x.received == K` → match event,
`reg` expressions → LUT4 state cells, `fn` bodies → descriptor rows with
contexts, `export stream` → stream PE.

## How a held-out protocol is supported

1. Written in `.spt` from its specification, without reference to the chip.
2. Compiled by the general lowering against `architecture/grid_3x3.json`
   alone; the compiler reports resource use (PEs, tracks, rows, contexts) or
   a precise unmappable-construct diagnostic.
3. Its own `test` blocks run at the pins against specification-written peers
   (`test_compiled.py`), then at gate level.
4. A failure is classified as compiler gap or missing PE and feeds the next
   change (the VTR loop), instead of a hand-written image.
