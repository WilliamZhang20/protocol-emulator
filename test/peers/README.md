Vendored from the sibling compiler's `sim/peers` (protocol-emulator-compiler,
`8338e15`) so the hardware CI can run compiled programs' own source tests
(`cocotb_tests/test_compiled.py`) without the compiler checkout. Each peer is a
device written from its protocol specification that also referees the wires.
Update by copying the compiler's `sim/peers/*.py` unchanged.
