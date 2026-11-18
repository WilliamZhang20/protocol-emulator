# Agent notes — protocol-emulator

## Gate-level–safe cocotb tests

Any test included in `COCOTB_TEST_MODULES` must be gate-level safe by default.
Synthesis flattens the design; `dut.user_project.core` and other internal
hierarchy do not exist under `GATES=yes` / `GL_TEST`.

**Rule:** do not access anything below `dut.user_project` unless the access is
guarded by an explicit GL/RTL check **and** the test is intentionally RTL-only.

```python
# BAD in shared RTL/GL tests
dut.user_project.core.state
dut.user_project.core.bit_xfer.busy
core = dut.user_project.core

# GOOD — top-level Tiny Tapeout pins and host link only
dut.ui_in
dut.uo_out
dut.uio_in
dut.uio_out
dut.uio_oe
```

Prefer black-box checks: host commands (program load, TX/RX, status `0xA`),
and GPIO (`uio_*`). Status byte is `{running, halted, tx_full, rx_empty, 4'b0}`.
After HALT the host clears `enable`, which also clears the core `halted` flag,
so bit 6 is not sticky — wait for `running == 0` (see `wait_until_halted`).

For orchestration / fuzz coverage that matters post-synthesis, rewrite
assertions to infer busy/halt/overlap from pins + status. Keep only deeply
implementation-specific scoreboarding behind an RTL-only guard (or a module
not listed in `COCOTB_TEST_MODULES` when `GATES=yes`). Do not exclude whole
`test_orchestrate.py` / `test_fuzz.py` from GL just to avoid hierarchy access.
