"""Run any compiled program's own source tests on the chip, at its pins.

Each program in test/data/compiled/ is three files the compiler produces:

  NAME.mem           the configuration image
  NAME.program.json  the backend's program record, whose `interface` says
                     which chip pin carries each source pin and how a call's
                     arguments become SRAM bytes and host words
  NAME.plan.json     the source's `test` blocks and `always` invariants, as
                     emitted by `spatial run --test` (hardware independent)

The runner knows nothing about any protocol. It loads the image, attaches
the plan's peers (test/peers, vendored from the compiler's sim/peers: devices
written from the protocol specifications that also referee the wires), runs
each step through the host link and checks the results, the peers' rule
checks and every invariant on every cycle. A fresh reset starts each test.
Only top-level pins are used, so it runs at gate level too.

Set COMPILED=path/to/NAME (without suffix) to run one program from anywhere.
"""
import json
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

import peers

DATA = Path(__file__).parents[1] / 'data' / 'compiled'
CHIP_PINS = {'uio0': 0, 'uio5': 5, 'uio6': 6}   # bidirectional pads by uio bit
STEP_TIMEOUT_CYCLES = 400_000


class Failure(Exception):
    pass


def fmt(data):
    return '[' + ', '.join(f'0x{b:02X}' for b in data) + ']'


class GridBus:
    """The wires around the chip, addressed by the plan's logical pads.

    Pads are pulled up; the chip and peers pull them low (wired-AND).
    `uo0` is the multiplexed third output: it is visible while the host link
    idles on opcode 7, which the runner holds during calls; otherwise the bus
    keeps its last observed level.
    """

    def __init__(self, dut, plan_pins, chip_pins, wires):
        self.dut = dut
        self.chip = {pad: chip_pins[name] for name, pad in plan_pins.items()}
        self.wires = {to: source for source, to in wires}
        self.drive = {}
        self.host_bits = 0
        self.uo0 = 1

    def _pin(self, pad):
        pad = self.wires.get(pad, pad)
        return self.chip.get(pad)

    def _chip(self, pin):
        """(level, driven) of a chip output pin."""
        if pin == 'uo0':
            return self.uo0, bool(int(self.dut.uio_oe.value) >> 7 & 1)
        bit = CHIP_PINS[pin]
        if int(self.dut.uio_oe.value) >> bit & 1:
            return int(self.dut.uio_out.value) >> bit & 1, True
        return 1, False

    def driven(self, pad):
        pad = self.wires.get(pad, pad)
        pin = self.chip.get(pad)
        return (pin is not None and self._chip(pin)[1]) or any(p == pad for p, _ in self.drive)

    def level(self, pad):
        pad = self.wires.get(pad, pad)
        pin = self.chip.get(pad)
        chip = self._chip(pin)[0] if pin is not None else 1
        return min([chip, *(v for (p, _), v in self.drive.items() if p == pad)])

    async def run(self):
        while True:
            await FallingEdge(self.dut.clk)
            await Timer(1, unit='ns')
            if (self.host_bits >> 2 & 7) == 7 and not (self.host_bits >> 1 & 1):
                self.uo0 = int(self.dut.uo_out.value) & 1
            value = self.host_bits
            for pad, pin in self.chip.items():
                if pin in CHIP_PINS:
                    value = (value & ~(1 << CHIP_PINS[pin])) | (self.level(pad) << CHIP_PINS[pin])
            # Inputs on uio[0] that no source pin uses idle high.
            if not any(pin == 'uio0' for pin in self.chip.values()):
                value |= 1
            self.dut.uio_in.value = value


class Invariants:
    """`always` conditions, checked every cycle (same semantics as sim/harness.py)."""

    def __init__(self, dut, bus, invariants):
        self.dut, self.bus, self.invariants, self.problems = dut, bus, invariants, []

    def holds(self, node, now, before):
        if 'const' in node:
            return bool(node['const'])
        if 'edge' in node:
            (a, was_driven), (b, is_driven) = before[node['pin']], now[node['pin']]
            if not (was_driven and is_driven):
                return False
            return {'changed': a != b, 'rise': not a and b, 'fall': a and not b}[node['edge']]
        if 'pin' in node:
            return bool(now[node['pin']][0])
        x = self.holds(node['a'], now, before)
        if node['op'] == 'not':
            return not x
        y = self.holds(node['b'], now, before)
        return {'&&': x and y, '||': x or y, '==': x == y, '!=': x != y, 'implies': not x or y}[node['op']]

    async def run(self):
        before, cycle = None, 0
        while True:
            await RisingEdge(self.dut.clk)
            now = [(self.bus.level(p), self.bus.driven(p)) for p in range(8)]
            for invariant in self.invariants:
                if before is not None and not self.holds(invariant['check'], now, before):
                    self.problems.append((invariant['name'], invariant['line'], cycle))
            before, cycle = now, cycle + 1


def evaluate(expr, args):
    """The interface's small argument language: a value or a list of bytes."""
    if isinstance(expr, int):
        return expr
    if isinstance(expr, list):
        out = []
        for item in expr:
            value = evaluate(item, args)
            out.extend(value if isinstance(value, list) else [value])
        return out
    if 'arg' in expr:
        return args[expr['arg']]
    if 'len' in expr:
        return len(args[expr['len']])
    if 'each' in expr:
        return [b for item in args[expr['each']] for b in evaluate(expr['bytes'], {**args, expr['as']: item})]
    if 'repeat' in expr:
        return [b for _ in range(evaluate(expr['repeat'], args)) for b in evaluate(expr['bytes'], args)]
    if 'last' in expr:  # the same item list, with `last` true for its final element
        items = args[expr['last']]
        return [b for i, item in enumerate(items)
                for b in evaluate(expr['bytes'], {**args, expr['as']: item, 'is_last': int(i == len(items) - 1)})]
    a, b = evaluate(expr['a'], args), evaluate(expr['b'], args)
    return {'+': a + b, '-': a - b, '*': a * b, '<<': a << b, '>>': a >> b, '|': a | b, '&': a & b,
            '==': int(a == b)}[expr['op']]


class Chip:
    """The host link of the Tiny Tapeout top (opcodes on uio[4:2], strobe uio[1])."""

    def __init__(self, dut, bus):
        self.dut, self.bus = dut, bus

    def _host(self, op, strobe):
        self.bus.host_bits = (op << 2) | (strobe << 1)

    async def command(self, op, data):
        await FallingEdge(self.dut.clk); self.dut.ui_in.value = data; self._host(op, 0)
        await ClockCycles(self.dut.clk, 4)
        await FallingEdge(self.dut.clk); self._host(op, 1)
        await ClockCycles(self.dut.clk, 5)
        await FallingEdge(self.dut.clk); self._host(op, 0)
        await ClockCycles(self.dut.clk, 4)

    async def idle(self, op):
        await FallingEdge(self.dut.clk); self._host(op, 0)
        await ClockCycles(self.dut.clk, 4)

    async def word(self, index, value):
        await self.command(1, 0); await self.command(0, index)
        await self.command(6, value & 255); await self.command(7, value >> 8)

    async def write(self, address, value):
        await self.command(0, address & 255); await self.command(1, address >> 8); await self.command(2, value)

    async def read(self, address):
        await self.command(0, address & 255); await self.command(1, address >> 8); await self.command(3, 0)
        await ClockCycles(self.dut.clk, 5); await FallingEdge(self.dut.clk)
        return int(self.dut.uo_out.value)

    async def status(self):
        await self.idle(4); await ClockCycles(self.dut.clk, 2); await FallingEdge(self.dut.clk)
        return int(self.dut.uo_out.value)


async def run_test(dut, image, program, plan, test):
    interface = program['interface']
    clock_ns = 1e9 / plan['clock_hz']
    clock = cocotb.start_soon(Clock(dut.clk, clock_ns, unit='ns').start())
    dut.ena.value = 1; dut.rst_n.value = 0; dut.ui_in.value = 0
    bus = GridBus(dut, plan['pins'], interface['pins'], test['wires'])
    chip = Chip(dut, bus)
    tasks = [cocotb.start_soon(bus.run())]
    try:
        await ClockCycles(dut.clk, 8)
        await FallingEdge(dut.clk); dut.rst_n.value = 1
        await ClockCycles(dut.clk, 8)
        # Load the image while disarmed, then arm with host words writable (cfg mode).
        await chip.command(4, 8)
        for index, word in enumerate(image):
            await chip.word(index, word)
        for index, word in interface.get('setup_words', {}).items():
            await chip.word(int(index), word)
        await chip.command(4, 0x0C)
        if not int(dut.uio_oe.value) & 0x80:
            raise Failure('the image did not arm (configuration rejected)')
        # Static SRAM contents, such as sequencer pages (host SRAM needs arm).
        for region in interface.get('setup_sram', []):
            for i, byte in enumerate(region['bytes']):
                await chip.write(region['base'] + i, byte)
        await chip.idle(7)
        attached = {}
        for spec in test['peers']:
            peer = peers.attach(spec, bus, dut)
            if isinstance(peer, str):
                raise Failure(f"line {spec['line']}: {peer}")
            attached[spec['name']] = peer
            tasks += [cocotb.start_soon(t) for t in peer.tasks()]
        invariants = Invariants(dut, bus, plan['invariants'])
        tasks.append(cocotb.start_soon(invariants.run()))
        timeout = test.get('step_timeout_cycles') or STEP_TIMEOUT_CYCLES
        received, consumed = {}, {}

        def check_rules(line):
            for name, peer in attached.items():
                if peer.problems:
                    raise Failure(f'line {line}: {name}: {peer.problems[0]}')
            if invariants.problems:
                name, at, cycle = invariants.problems[0]
                raise Failure(f'line {line}: `always "{name}"` (line {at}) broke at cycle {cycle}')

        for step in test['steps']:
            line = step['line']
            if step['op'] == 'call':
                function = interface['functions'].get(step['function'])
                if function is None:
                    raise Failure(f"line {line}: {step['function']}() was not compiled for this chip")
                args = step['args']
                for word, expr in function.get('words', {}).items():
                    await chip.word(int(word), evaluate(expr, args))
                for region in function.get('sram', []):
                    for i, byte in enumerate(evaluate(region['bytes'], args)):
                        await chip.write(region['base'] + i, byte)
                await chip.command(5, 0)
                await chip.idle(7)
                for _ in range(timeout):
                    await FallingEdge(dut.clk); await Timer(1, unit='ns')
                    if int(dut.uio_out.value) & 0x80:
                        break
                else:
                    raise Failure(f"line {line}: {step['function']}() did not finish in {timeout} cycles")
                await ClockCycles(dut.clk, 2)
                check_rules(line)  # protocol and invariant violations explain a wrong result best
                failed = bool(await chip.status() & 0x40)
                expected_failure = step.get('fails')
                if failed and expected_failure is None:
                    raise Failure(f"line {line}: {step['function']}() failed (chip reported an error)")
                if expected_failure is not None:
                    if not failed:
                        raise Failure(f"line {line}: {step['function']}() should fail with \"{expected_failure}\"")
                elif 'expect' in step:
                    reply = function['reply']
                    base = evaluate(reply['base'], args)
                    got = [await chip.read(base + i) for i in range(evaluate(reply['count'], args))]
                    if got != step['expect']:
                        raise Failure(f"line {line}: {step['function']}() returned {fmt(got)}, expected {fmt(step['expect'])}")
                await chip.idle(7)
                check_rules(line)
            elif step['op'] == 'write' and 'stream' in step['target']:
                stream = interface['streams'][step['target']['stream']]
                for i, byte in enumerate(step['bytes']):
                    await chip.write(stream['base'] + i, byte)
                await chip.word(stream['length_word'], len(step['bytes']))
                await chip.command(5, 0)
                await chip.idle(7)
                for _ in range(timeout):
                    await FallingEdge(dut.clk); await Timer(1, unit='ns')
                    if int(dut.uio_out.value) & 0x80:
                        break
                else:
                    raise Failure(f"line {line}: stream {step['target']['stream']} did not finish sending")
                if await chip.status() & 0x40:
                    raise Failure(f"line {line}: stream {step['target']['stream']} reported a send error")
                await chip.idle(7)
                check_rules(line)
            elif step['op'] == 'read' and 'stream' in step['target']:
                name = step['target']['stream']
                stream = interface['streams'][name]
                # Idle opcode 5 shows the low byte of the received count.
                await chip.idle(5)
                for _ in range(timeout // 64):
                    await ClockCycles(dut.clk, 64); await FallingEdge(dut.clk)
                    count = int(dut.uo_out.value)
                    received[name] = received.get(name, 0) + ((count - received.get(name, 0)) & 255)
                    if received[name] - consumed.get(name, 0) >= step['count']:
                        break
                else:
                    raise Failure(f"line {line}: stream {name} received {received.get(name, 0) - consumed.get(name, 0)} of {step['count']} bytes")
                start = consumed.get(name, 0)
                if start + step['count'] > stream['capacity']:
                    raise Failure(f"line {line}: stream {name} exceeds its {stream['capacity']}-byte region")
                got = [await chip.read(stream['base'] + start + i) for i in range(step['count'])]
                consumed[name] = start + step['count']
                await chip.idle(7)
                if got != step['expect']:
                    raise Failure(f"line {line}: {name}.read({step['count']}) returned {fmt(got)}, expected {fmt(step['expect'])}")
                check_rules(line)
            elif step['op'] == 'read' and 'peer' in step['target']:
                peer = attached[step['target']['peer']]
                got = peer.received[:step['count']]
                if got != step['expect']:
                    raise Failure(f"line {line}: {step['target']['peer']} received {fmt(got)}, expected {fmt(step['expect'])}")
                del peer.received[:step['count']]
            elif step['op'] == 'write' and 'peer' in step['target']:
                attached[step['target']['peer']].write(step['bytes'])
            else:
                raise Failure(f"line {line}: step `{step['op']}` is not supported by the compiled-program runner")
        await ClockCycles(dut.clk, 20)
        check_rules(test['line'])
        for peer in attached.values():
            if hasattr(peer, 'finish'):
                peer.finish()
    finally:
        for task in tasks:
            task.cancel()
        clock.cancel()


def programs():
    if os.environ.get('COMPILED'):
        return [Path(os.environ['COMPILED'])]
    return sorted(p.with_suffix('').with_suffix('') for p in DATA.glob('*.plan.json'))


def make_test(stem):
    async def compiled_program(dut):
        image = [int(x, 16) for x in Path(f'{stem}.mem').read_text().splitlines()]
        program = json.loads(Path(f'{stem}.program.json').read_text())
        plan = json.loads(Path(f'{stem}.plan.json').read_text())
        failures = []
        for test in plan['tests']:
            try:
                await run_test(dut, image, program, plan, test)
                dut._log.info('%s: test "%s" passed', stem.name, test['name'])
            except Failure as error:
                failures.append(f"\"{test['name']}\": {error}")
                dut._log.error('%s: test "%s" failed: %s', stem.name, test['name'], error)
        assert not failures, failures
    compiled_program.__name__ = compiled_program.__qualname__ = f'compiled_{stem.name.replace("-", "_")}'
    return cocotb.test()(compiled_program)


for _stem in programs():
    globals()[f'compiled_{_stem.name.replace("-", "_")}'] = make_test(_stem)
