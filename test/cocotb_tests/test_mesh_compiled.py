"""Run a program compiled for the reorganised fabric's mesh with its own
source tests, at the mesh's pads (FABRIC_REORG.md step 4).

The compiler (protocol-emulator-compiler circt_lab/fabric_build.py)
writes three files per program:

  NAME.hex        the configuration vector for experiments/grid_fabric/reorg/mesh.v
  NAME.plan.json  the source's `test` blocks and `always` invariants
  NAME.mesh.json  mesh parameters and the interface: the port of each host
                  stream (reader, writer, or a shifter's host port by cell),
                  and each exported function's host plan

The DUT is mesh_soc.v: the mesh with the real stream reader, writer and
two-bank SRAM. The runner knows no protocol. It loads the vector,
attaches the plan's peers (test/peers) to the pads, and plays the host:
a stream write puts the bytes into SRAM bank 0 through the host port and
sends them with the reader; a receive stream's writer fills a region of
bank 1, read back through the host port. It checks results, the peers'
rules and every invariant each cycle. Pads are the plan's logical pins; a pad is the AND
of the mesh's drive (push-pull or open drain) and the peers' (wired-AND,
pulled up).

A function call runs its host plan (FABRIC_REORG.md step 4 L3): clear the
sticky flags, send `via` arguments through SRAM and the reader, write
parameters into idle tiles, fire host events, wait on flags or result
bytes, and read the result back from SRAM. The fabric does the rest. A
program with functions runs every test twice: with no host delay and with
HOST_DELAY clocks (default 997) before every host step, which measures that
the host steps tolerate host latency.

MESH=path/NAME (without suffix) selects the program; the mesh parameters
are compiled in by test/Makefile.mesh from NAME.mesh.json.
"""
import json
import os
from pathlib import Path

import cocotb
import cocotb.utils
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

import peers
from cocotb_tests.test_compiled import Failure, Invariants, fmt

STEP_TIMEOUT_CYCLES = 400_000
HOST_DELAY = int(os.environ.get('HOST_DELAY', 997))


def host_value(x, args):
    if isinstance(x, int):
        return x
    if 'arg' in x:
        return args[x['arg']]
    if 'len' in x:
        return len(args[x['len']])
    a, b = host_value(x['a'], args), host_value(x['b'], args)
    return {'+': a + b, '-': a - b, '*': a * b, '<<': a << b, '>>': a >> b, '|': a | b, '&': a & b}[x['op']]


class MeshBus:
    """The wires around the mesh, addressed by logical pad (0-7)."""

    def __init__(self, dut, wires):
        self.dut = dut
        self.wires = {to: source for source, to in wires}
        self.drive = {}

    def _chip(self, pad):
        oe = int(self.dut.pad_oe.value) >> pad & 1
        if oe:
            return int(self.dut.pad_out.value) >> pad & 1, True
        return 1, False

    def driven(self, pad):
        pad = self.wires.get(pad, pad)
        return self._chip(pad)[1] or any(p == pad for p, _ in self.drive)

    def level(self, pad):
        pad = self.wires.get(pad, pad)
        return min([self._chip(pad)[0], *(v for (p, _), v in self.drive.items() if p == pad)])

    async def run(self):
        while True:
            await FallingEdge(self.dut.clk)
            await Timer(1, unit='ns')
            self.dut.pins.value = sum(self.level(p) << p for p in range(8))


TX_BASE, RX_BASE, RX_CAPACITY = 0, 1024, 1024     # bank 0 for sends, bank 1 for receives


class Host:
    """The host side: SRAM through the memory's host port, the stream
    reader and writer, and shifters' direct host ports."""

    def __init__(self, dut, interface):
        self.dut, self.interface = dut, interface
        self.got = {name: [] for name, s in interface['streams'].items() if s['port'] == 'host'}

    async def run(self):
        """Collect bytes from direct host ports."""
        dut = self.dut
        streams = self.interface['streams']
        while True:
            await RisingEdge(dut.clk)
            await Timer(1, unit='ps')
            for name, s in streams.items():
                if s['port'] == 'host' and int(dut.host_valid.value) >> s['cell'] & 1:
                    self.got[name].append(int(dut.host_byte.value) >> (8 * s['cell']) & 255)

    async def mem(self, addr, data=None):
        """host_ready is the memory's grant for the current clock (combinational),
        so it is sampled between edges: the next rising edge performs the access,
        and a read's rvalid/rdata follow one clock later."""
        dut = self.dut
        await FallingEdge(dut.clk)
        dut.host_req.value = 1; dut.host_we.value = int(data is not None)
        dut.host_addr.value = addr; dut.host_wdata.value = data or 0
        for _ in range(64):
            await Timer(1, unit='ps')
            if int(dut.host_ready.value):
                break
            await FallingEdge(dut.clk)
        else:
            raise Failure(f'SRAM host access to {addr} never granted')
        await FallingEdge(dut.clk); dut.host_req.value = 0; dut.host_we.value = 0
        if data is None:
            if not int(dut.host_rvalid.value):
                raise Failure(f'SRAM host read of {addr} returned nothing')
            return int(dut.host_rdata.value)

    async def strobe(self, **values):
        """Drive signals for one clock (from a falling edge), then zero them."""
        dut = self.dut
        await FallingEdge(dut.clk)
        for k, v in values.items():
            getattr(dut, k).value = v
        await FallingEdge(dut.clk)
        for k in values:
            getattr(dut, k).value = 0

    async def pulse(self, sig, base_sig, base, len_sig, length):
        dut = self.dut
        await FallingEdge(dut.clk)
        base_sig.value = base; len_sig.value = length; sig.value = 1
        await FallingEdge(dut.clk); sig.value = 0


async def call(dut, host, interface, step, delay, timeout):
    """Run one function call's host plan; returns its result bytes."""
    fn = interface['functions'][step['function']]
    args = step['args']
    start = int(dut.wr_count.value)
    result = None
    for st in fn['steps']:
        if delay:
            await ClockCycles(dut.clk, delay)
        op = st['op']
        if op == 'clear':
            await host.strobe(seen_clear=1)
        elif op == 'send':
            data = args[st['arg']]
            for i, b in enumerate(data):
                await host.mem(TX_BASE + i, b)
            await host.pulse(dut.rd_start, dut.rd_base, TX_BASE, dut.rd_length, len(data))
        elif op == 'param':
            await host.strobe(param_we=1, param_cell=st['cell'], param_addr=st['addr'],
                              param_data=host_value(st['value'], args) & 0xffff)
        elif op == 'fire':
            await host.strobe(host_ev=1 << st['index'])
        elif op in ('wait', 'wait_bytes'):
            n = host_value(st['count'], args) if op == 'wait_bytes' else None
            for _ in range(timeout):
                await RisingEdge(dut.clk)
                if (int(dut.wr_count.value) - start >= n) if n is not None else (int(dut.seen.value) >> st['flag'] & 1):
                    break
            else:
                what = f'{n} result bytes' if n is not None else st['signal']
                raise Failure(f"line {step['line']}: {step['function']}: no {what}")
        elif op == 'reply':
            n = int(dut.wr_count.value) - start
            result = [await host.mem(RX_BASE + start + i) for i in range(n)]
    return result


async def run_test(dut, vector, interface, plan, test, delay=0):
    clock_ns = 1e9 / plan['clock_hz']
    clock = cocotb.start_soon(Clock(dut.clk, clock_ns, unit='ns').start())
    dut.rst_n.value = 0; dut.run_req.value = 0; dut.cfg.value = vector; dut.pins.value = 0xff
    for sig in (dut.host_req, dut.host_we, dut.host_addr, dut.host_wdata, dut.rd_start, dut.rd_base, dut.rd_length,
                dut.wr_start, dut.wr_base, dut.wr_length, dut.host_ev, dut.seen_clear, dut.param_we, dut.param_cell,
                dut.param_addr, dut.param_data):
        sig.value = 0
    bus = MeshBus(dut, test['wires'])
    host = Host(dut, interface)
    tasks = [cocotb.start_soon(bus.run()), cocotb.start_soon(host.run())]
    try:
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk); dut.rst_n.value = 1
        for _ in range(64):
            await RisingEdge(dut.clk)
            if int(dut.ready.value):
                break
        else:
            raise Failure('the mesh did not finish loading its configuration')
        if any(s['port'] == 'writer' for s in interface['streams'].values()) or \
                any(f.get('returns') == 'writer' for f in interface.get('functions', {}).values()):
            await host.pulse(dut.wr_start, dut.wr_base, RX_BASE, dut.wr_length, RX_CAPACITY)
        await FallingEdge(dut.clk); dut.run_req.value = 1
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
        consumed = {}

        def check_rules(line):
            for name, peer in attached.items():
                if peer.problems:
                    raise Failure(f'line {line}: {name}: {peer.problems[0]}')
            if invariants.problems:
                name, at, cycle = invariants.problems[0]
                raise Failure(f'line {line}: `always "{name}"` (line {at}) broke at cycle {cycle}')

        for step in test['steps']:
            line = step['line']
            if step['op'] == 'write' and 'stream' in step['target']:
                name = step['target']['stream']
                if interface['streams'].get(name, {}).get('port') != 'reader':
                    raise Failure(f'line {line}: stream {name} is not a host -> mesh stream')
                for i, b in enumerate(step['bytes']):
                    await host.mem(TX_BASE + i, b)
                await host.pulse(dut.rd_start, dut.rd_base, TX_BASE, dut.rd_length, len(step['bytes']))
                for _ in range(timeout):
                    await RisingEdge(dut.clk)
                    if int(dut.rd_done.value) or not int(dut.rd_active.value):
                        break
                else:
                    raise Failure(f'line {line}: stream {name}: the reader never finished')
                check_rules(line)
            elif step['op'] == 'read' and 'stream' in step['target']:
                name = step['target']['stream']
                start = consumed.get(name, 0)
                via_sram = interface['streams'][name]['port'] == 'writer'
                have = (lambda: int(dut.wr_count.value)) if via_sram else (lambda: len(host.got[name]))
                for _ in range(timeout):
                    await RisingEdge(dut.clk)
                    if have() - start >= step['count']:
                        break
                else:
                    raise Failure(f"line {line}: stream {name} received {have() - start} of {step['count']} bytes")
                if via_sram:
                    got = [await host.mem(RX_BASE + start + i) for i in range(step['count'])]
                else:
                    got = host.got[name][start:start + step['count']]
                consumed[name] = start + step['count']
                if got != step['expect']:
                    raise Failure(f"line {line}: {name}.read({step['count']}) returned {fmt(got)}, expected {fmt(step['expect'])}")
                check_rules(line)
            elif step['op'] == 'read' and 'peer' in step['target']:
                peer = attached[step['target']['peer']]
                for _ in range(timeout):
                    await RisingEdge(dut.clk)
                    if len(peer.received) >= step['count']:
                        break
                got = peer.received[:step['count']]
                if got != step['expect']:
                    raise Failure(f"line {line}: {step['target']['peer']} received {fmt(got)}, expected {fmt(step['expect'])}")
                del peer.received[:step['count']]
                check_rules(line)
            elif step['op'] == 'write' and 'peer' in step['target']:
                attached[step['target']['peer']].write(step['bytes'])
            elif step['op'] == 'call' and step['function'] in interface.get('functions', {}):
                if 'fails' in step:
                    raise Failure(f"line {line}: an expected failure (`fails`) is not lowered yet")
                t0 = cocotb.utils.get_sim_time('ns')
                got = await call(dut, host, interface, step, delay, timeout)
                dut._log.info('call %s(%s): %d clocks, host delay %d', step['function'], fmt(sum(
                    (v if isinstance(v, list) else [v] for v in step['args'].values()), [])),
                    round((cocotb.utils.get_sim_time('ns') - t0) / clock_ns), delay)
                if 'expect' in step and got != step['expect']:
                    raise Failure(f"line {line}: {step['function']} returned {fmt(got)}, expected {fmt(step['expect'])}")
                check_rules(line)
            else:
                raise Failure(f"line {line}: step `{step['op']}` is not lowered yet (step 4 L3)")
        await ClockCycles(dut.clk, 20)
        check_rules(test['line'])
        for peer in attached.values():
            if hasattr(peer, 'finish'):
                peer.finish()
    finally:
        for task in tasks:
            task.cancel()
        clock.cancel()


@cocotb.test()
async def mesh_compiled_program(dut):
    stem = os.environ['MESH']
    words = [int(x, 16) for x in Path(stem + '.hex').read_text().split()]
    vector = sum(w << (32 * i) for i, w in enumerate(words))
    interface = json.loads(Path(stem + '.mesh.json').read_text())
    plan = json.loads(Path(stem + '.plan.json').read_text())
    failures = []
    delays = [0, HOST_DELAY] if interface.get('functions') else [0]
    for test in plan['tests']:
        for delay in delays:
            tag = f' (host delay {delay})' if delay else ''
            try:
                await run_test(dut, vector, interface, plan, test, delay)
                dut._log.info('%s: test "%s" passed%s', Path(stem).name, test['name'], tag)
            except Failure as error:
                failures.append(f"\"{test['name']}\"{tag}: {error}")
                dut._log.error('%s: test "%s" failed%s: %s', Path(stem).name, test['name'], tag, error)
    assert not failures, failures
