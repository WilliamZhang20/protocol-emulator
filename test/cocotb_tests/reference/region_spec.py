"""Pure Python cycle model for the action region timing subset.

The model uses decoded action words and has no cocotb or RTL dependencies.
Unsupported opcodes fail loudly so randomized differential tests cannot
silently treat a newly generated instruction as a NOP.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class PinChange:
    cycle: int
    output: int
    output_enable: int


class RegionSpec:
    """One action per clock for GPIO, DELAY, COUNT, REPEAT, and DONE."""

    def __init__(self, slots: list[int], *, start: int = 0, extras: int = 0):
        if not 0 <= start < len(slots) <= 16:
            raise ValueError("region must contain 1..16 slots and a valid start")
        if not 0 <= extras <= 255:
            raise ValueError("extra passes must fit in eight bits")
        self.slots = slots
        self.pc = start
        self.start = start
        self.repeats_left = extras
        self.counter = 0
        self.delay_counter = 0
        self.delaying = False
        self.done = False
        self.cycle = 0
        self.output = 0
        self.oe = 0
        self.claim = self._claim()

    def _claim(self) -> int:
        mask = 0
        for word in self.slots:
            op = (word >> 12) & 15
            args = word & 0xFFF
            if op == 1:
                mask |= 1 << (args & 7)
        return mask

    def step(self) -> PinChange | None:
        if self.done:
            raise RuntimeError("region already complete")
        before = (self.output, self.oe)
        if self.delaying:
            if self.delay_counter == 0:
                self.delaying = False
                self.pc += 1
            else:
                self.delay_counter -= 1
        else:
            word = self.slots[self.pc]
            op = (word >> 12) & 15
            args = word & 0xFFF
            if op == 0:  # NOP
                self.pc += 1
            elif op == 1:  # GPIO
                bit = 1 << (args & 7)
                if args & (1 << 9):
                    self.output = (self.output & ~bit) | (bit if args & (1 << 8) else 0)
                if args & (1 << 11):
                    self.oe = (self.oe & ~bit) | (bit if args & (1 << 10) else 0)
                self.pc += 1
            elif op == 4:  # COUNT
                mode = (args >> 10) & 3
                if mode == 0:
                    self.counter = args & 255
                    self.pc += 1
                elif mode == 1:
                    self.counter = (self.counter + 1) & 255
                    self.pc += 1
                elif mode == 2:
                    self.counter = (self.counter - 1) & 255
                    self.pc += 1
                elif self.counter != 1:
                    self.counter = (self.counter - 1) & 255
                    self.pc = args & 15
                else:
                    self.counter = 0
                    if args & (1 << 9):
                        self.done = True
                    else:
                        self.pc += 1
            elif op == 7:  # DELAY
                length = args & 255
                if args & (1 << 11):
                    raise ValueError("conditional delays need a sampled pin")
                if length == 0:
                    self.pc += 1
                else:
                    self.delay_counter = length - 1
                    self.delaying = True
            elif op == 8:  # REPEAT
                self.pc = args & 15
            elif op == 9:  # DONE
                if self.repeats_left:
                    self.repeats_left -= 1
                    self.pc = self.start
                else:
                    self.done = True
            else:
                raise ValueError(f"unsupported differential opcode {op:X}")

        change = None
        if (self.output, self.oe) != before:
            change = PinChange(self.cycle, self.output, self.oe)
        self.cycle += 1
        return change

    def trace(self, *, max_cycles: int = 2048) -> list[PinChange]:
        changes = []
        for _ in range(max_cycles):
            change = self.step()
            if change is not None:
                changes.append(change)
            if self.done:
                return changes
        raise AssertionError("reference region failed to finish")
