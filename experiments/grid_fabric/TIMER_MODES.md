# Timer modes (step 2.1)

All four timers are `grid_timer` (`src/grid_timer.v`). A mode word and a
phase word per timer (configuration words 208-215, `{mode, phase}` for
timers 0-3, each written from its timer's cell) select what the timer's
third input `aux` does:

| Function (mode[1:0]) | `aux` |
|---|---|
| 0 hold | high pauses counting. The reset value, so every earlier image keeps its timing. |
| 1 count | the count steps on `aux` pulses instead of clocks: a tick after N input events. |
| 2 capture | a pulse latches the clocks since the previous pulse (or arming) into the capture register and restarts that count; saturates at 65535; runs whether or not the timer does. |
| 3 resync | a pulse while running moves the count to `phase`, at most `mode[15:8]` clocks away (0: no limit): the next tick lands `phase` clocks after the edge. |

`mode[7:2]` are reserved and must be zero, or the fabric does not
configure. Timer 0 and 1 captures are lane readback slots 6 and 7
(`RD readback:timer0_capture`).

First and period are shadowed: a live write while armed lands at the next
reload, so a running period is never cut short. The live-write path is
tied off until lanes own words (step 2.5); the shadow is proven and
tile-tested now.

## Evidence

- `formal/grid_timer`: k-induction against an independently written
  reference model (W = 8, every input arbitrary each clock) plus spec
  properties (hold freezes, count ticks only after a pulse, resync stays in
  its limit); 8 RTL mutations, all caught (`make -C formal grid_timer
  grid_timer-mutations`, in CI).
- `experiments/fabric_v2/timer_tb.sv`: hold mode is cycle-for-cycle the
  old `fabric_v2_timer` over 20,000 random clocks; count, capture, limited
  and unlimited resync, and the shadowed live write.
- `tools/check_grid_contract.py`: mode word addresses, owning cells, field
  layout, function codes and capture readback slots checked against the RTL,
  with contract mutations.
- Pin tests (`test/cocotb_tests/test_lane_timer.py`, designs compiled from
  `protocol-emulator-compiler/circt_lab/lanes/`, where `timer_modes` in a
  lane design becomes these words):
  - **pulse_period** (capture): periods 137, 1000, 65 and 4321 clocks
    read back exactly; 70000 reads 65535.
  - **uart_rx_resync / uart_rx_plain**: UART receive at 20 clocks per bit
    from a sender 6% slow or fast. With resync on every falling edge
    (phase 9, limit 8) all eight frames arrive at 0% and +/-6%. Without
    it, +6% fails the stop-bit check on the first frame and -6% corrupts
    four bytes. Margin beyond the requirement (logged, not asserted): -9%
    corrupts one byte; +9% fails on the third frame (0x3C, whose four-bit
    runs give no edge to resync on).
