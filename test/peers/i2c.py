"""An I2C target (peripheral) with registers, on open-drain SCL and SDA.

It answers at a 7-bit `address`. The first byte of a write sets the register
pointer; later bytes are stored there and the pointer advances. Reads return
`registers` from the pointer on. With `stretch`, it holds SCL low for that
many cycles after every acknowledge, as a slow device does.

As a referee it fails the test on a START or STOP after the first bit of a byte.
`received` holds every byte written to it, register pointers included.
"""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge


class I2cTarget:
    def __init__(self, bus, dut, name, scl, sda, address, registers, stretch=0):
        self.bus, self.dut, self.name = bus, dut, name
        self.scl, self.sda, self.address = scl, sda, address
        self.registers, self.stretch = list(registers), stretch
        self.received, self.problems = [], []
        self.pointer = 0
        self.expect_pointer = False

    def tasks(self):
        return [self._run()]

    def write(self, data):
        self.registers.extend(data)

    def _sda(self, level):
        if level is None or level == 1:
            self.bus.drive.pop((self.sda, self.name), None)
        else:
            self.bus.drive[(self.sda, self.name)] = 0

    async def _hold_scl(self):
        self.bus.drive[(self.scl, self.name)] = 0
        await ClockCycles(self.dut.clk, self.stretch)
        self.bus.drive.pop((self.scl, self.name), None)

    def _next_register(self):
        value = self.registers[self.pointer] if self.pointer < len(self.registers) else 0xFF
        self.pointer += 1
        return value

    async def _run(self):
        phase, shift, bits, reading, out = "idle", 0, 0, False, 0
        await RisingEdge(self.dut.clk)
        prev_scl, prev_sda = self.bus.level(self.scl), self.bus.level(self.sda)
        while True:
            await RisingEdge(self.dut.clk)
            scl, sda = self.bus.level(self.scl), self.bus.level(self.sda)
            if scl and prev_scl and sda != prev_sda:
                # A repeated START or STOP looks like a first data bit until SDA moves,
                # so conditions are legal up to the first bit of a byte.
                if phase in ("addr", "write") and 1 < bits < 8 or phase == "tx":
                    self.problems.append(f"{'START' if not sda else 'STOP'} in the middle of a byte")
                if not sda:  # START, or repeated START
                    phase, shift, bits, reading = "addr", 0, 0, False
                    self.expect_pointer = True
                else:  # STOP
                    phase = "idle"
                self._sda(None)
            elif scl and not prev_scl:  # SCL rose: data is valid
                if phase in ("addr", "write"):
                    shift, bits = (shift << 1 | sda) & 0xFF, bits + 1
                elif phase == "controller_ack":
                    phase = "send" if sda == 0 else "idle"
            elif not scl and prev_scl:  # SCL fell: drive the next bit
                if phase in ("addr", "write") and bits == 8:
                    if phase == "addr" and shift >> 1 != self.address:
                        phase = "idle"
                    else:
                        self.received += [] if phase == "addr" else [shift]
                        if phase == "addr":
                            reading = bool(shift & 1)
                        elif self.expect_pointer:
                            self.pointer, self.expect_pointer = shift, False
                        else:
                            while len(self.registers) <= self.pointer:
                                self.registers.append(0xFF)
                            self.registers[self.pointer] = shift
                            self.pointer += 1
                        self._sda(0)
                        phase = "ack"
                elif phase == "ack":
                    if self.stretch:
                        cocotb.start_soon(self._hold_scl())
                    if reading:
                        out = self._next_register()
                        self._sda(out >> 7 & 1)
                        bits, phase = 1, "tx"
                    else:
                        self._sda(None)
                        shift, bits, phase = 0, 0, "write"
                elif phase == "tx":
                    if bits < 8:
                        self._sda(out >> (7 - bits) & 1)
                        bits += 1
                    else:
                        self._sda(None)
                        phase = "controller_ack"
                elif phase == "send":
                    out = self._next_register()
                    self._sda(out >> 7 & 1)
                    bits, phase = 1, "tx"
            prev_scl, prev_sda = scl, sda
