"""Reference 16-state TAP with IDCODE, 4-bit IR and an 8-bit user register."""
from cocotb.triggers import RisingEdge

IDCODE = 0x1BA0_0477
IR_LEN = 4
IR_IDCODE, IR_USER, IR_BYPASS = 0b1110, 0b1010, 0b1111

# TAP state -> (next if TMS=0, next if TMS=1)
NEXT = {
    "RESET": ("IDLE", "RESET"), "IDLE": ("IDLE", "SELECT_DR"),
    "SELECT_DR": ("CAPTURE_DR", "SELECT_IR"), "CAPTURE_DR": ("SHIFT_DR", "EXIT1_DR"),
    "SHIFT_DR": ("SHIFT_DR", "EXIT1_DR"), "EXIT1_DR": ("PAUSE_DR", "UPDATE_DR"),
    "PAUSE_DR": ("PAUSE_DR", "EXIT2_DR"), "EXIT2_DR": ("SHIFT_DR", "UPDATE_DR"),
    "UPDATE_DR": ("IDLE", "SELECT_DR"), "SELECT_IR": ("CAPTURE_IR", "RESET"),
    "CAPTURE_IR": ("SHIFT_IR", "EXIT1_IR"), "SHIFT_IR": ("SHIFT_IR", "EXIT1_IR"),
    "EXIT1_IR": ("PAUSE_IR", "UPDATE_IR"), "PAUSE_IR": ("PAUSE_IR", "EXIT2_IR"),
    "EXIT2_IR": ("SHIFT_IR", "UPDATE_IR"), "UPDATE_IR": ("IDLE", "SELECT_DR"),
}


class JtagTap:
    def __init__(self, bus, dut, name, tck, tms, tdi, tdo):
        self.bus, self.dut, self.name = bus, dut, name
        self.tck, self.tms, self.tdi, self.tdo = tck, tms, tdi, tdo
        self.state, self.ir, self.user = "RESET", IR_IDCODE, 0
        self.shift, self.length, self.output = 0, 1, 1
        self.received, self.problems = [], []

    def tasks(self):
        return [self.run()]

    def write(self, data):
        raise ValueError("TAP registers are written through JTAG scans")

    async def run(self):
        prev = 0
        old = (1, 1)
        while True:
            await RisingEdge(self.dut.clk)
            clock = self.bus.level(self.tck) if self.bus.driven(self.tck) else 0
            pins = (self.bus.level(self.tms), self.bus.level(self.tdi))
            if clock and prev and pins != old:
                self.problems.append("TMS/TDI changed while TCK was high")
            if clock and not prev:
                tms, tdi = pins
                if self.state in ("SHIFT_DR", "SHIFT_IR"):
                    self.shift = self.shift >> 1 | tdi << (self.length - 1)
                nxt = NEXT[self.state][tms]
                if nxt == "CAPTURE_DR":
                    self.shift, self.length = ((IDCODE, 32) if self.ir == IR_IDCODE else
                                              (self.user, 8) if self.ir == IR_USER else (0, 1))
                elif nxt == "CAPTURE_IR":
                    self.shift, self.length = 1, IR_LEN
                elif nxt == "UPDATE_IR":
                    self.ir = self.shift
                elif nxt == "UPDATE_DR" and self.ir == IR_USER:
                    self.user = self.shift
                    self.received.append(self.user)
                elif nxt == "RESET":
                    self.ir = IR_IDCODE
                self.state = nxt
                self.output = self.shift & 1 if nxt in ("SHIFT_DR", "SHIFT_IR") else 1
            if prev and not clock:
                self.bus.drive[(self.tdo, self.name)] = self.output
            prev, old = clock, pins
