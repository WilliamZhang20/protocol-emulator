"""Independent digital 10BASE-T observer at 40 MHz.

No RTL configuration knowledge: decode differential Manchester cells, then
check preamble, CRC32 via zlib, link-pulse timing and frame-end idle. This
is not an analog PHY model or collision/auto-negotiation implementation.
"""
import zlib
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time


class EthernetLink:
    def __init__(self, bus, dut, name, positive, negative, frames=1, pulses=3, pulse_period=640000):
        if frames < 1 or pulses < 0 or pulse_period < 1:
            raise ValueError("expected positive frame count/period and nonnegative pulse count")
        self.bus, self.dut, self.name = bus, dut, name
        self.positive, self.negative = positive, negative
        self.expected_frames, self.expected_pulses = frames, pulses
        self.pulse_period = pulse_period
        self.received, self.problems = [], []
        self.frames, self.pulses, self.last_pulse = 0, 0, None

    def tasks(self):
        return [self.run()]

    def write(self, data):
        self.problems.append("this peer only observes transmit waveforms")

    def finish(self):
        if (self.frames, self.pulses) != (self.expected_frames, self.expected_pulses):
            self.problems.append(f"expected {self.expected_frames} frames/{self.expected_pulses} link pulses, got {self.frames}/{self.pulses}")

    def decode(self, states, start):
        if states == [(1, 0)] * 4:
            self.pulses += 1
            if self.last_pulse is not None and start - self.last_pulse != self.pulse_period:
                self.problems.append(f"link pulses were {start - self.last_pulse} clocks apart, expected {self.pulse_period}")
            self.last_pulse = start
            return
        if len(states) < (8 + 60 + 4) * 32 + 12:
            self.problems.append(f"short or malformed link pulse/frame ({len(states)} clocks)")
            return
        body, idle = states[:-12], states[-12:]
        if idle != [(1, 0)] * 12 or len(body) % 32:
            self.problems.append(f"frame has wrong length or TP_IDL: {len(states)} clocks (expected whole bytes plus 12 idle clocks)")
            return
        bits = []
        for i in range(0, len(body), 4):
            first, second = body[i:i+2], body[i+2:i+4]
            if len(set(first)) != 1 or len(set(second)) != 1 or first[0] not in ((1, 0), (0, 1)) or second[0] != first[0][::-1]:
                self.problems.append(f"invalid Manchester half bit at clock {i}")
                return
            bits.append(int(second[0] == (1, 0)))
        data = bytes(sum(bits[i+j] << j for j in range(8)) for i in range(0, len(bits), 8))
        if data[:8] != bytes([0x55] * 7 + [0xD5]):
            self.problems.append(f"bad preamble/SFD: {data[:8].hex()}")
            return
        frame, check = data[8:-4], data[-4:]
        if check != zlib.crc32(frame).to_bytes(4, "little"):
            self.problems.append(f"bad Ethernet FCS: {check.hex()}")
            return
        self.frames += 1
        self.received.extend(frame)

    async def run(self):
        states, cycle, start = [], 0, 0
        previous_time = None
        while True:
            await RisingEdge(self.dut.clk)
            now = get_sim_time("ps")
            if previous_time is not None and now - previous_time != 25000:
                self.problems.append("10BASE-T observer requires a 40 MHz core clock")
                return
            previous_time = now
            cycle += 1
            driven = self.bus.driven(self.positive) and self.bus.driven(self.negative)
            state = (self.bus.level(self.positive), self.bus.level(self.negative)) if driven else (0, 0)
            if state == (0, 0):
                if states:
                    self.decode(states, start)
                    states = []
            else:
                if not states:
                    start = cycle
                states.append(state)
                if len(states) > 60000:
                    self.problems.append("transmitter never returned to idle")
                    return
