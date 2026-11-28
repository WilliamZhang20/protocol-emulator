"""Run a program compiled for the reorganised fabric's mesh with its own
source tests, at the mesh's pads (FABRIC_REORG.md step 4).

The compiler (protocol-emulator-compiler circt_lab/fabric_build.py)
writes three files per program:

  NAME.hex        the configuration vector for src/mesh.v
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
sticky flags, select a mode (a host event), send `via` arguments or a loaded
value through SRAM and the reader, write parameters into idle tiles, fire
host events, wait on flags or result bytes, and read the result back from
SRAM (masked if the source says `& mask`). The fabric does the rest. A
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
from cocotb.triggers import ClockCycles, FallingEdge, Lock, RisingEdge, Timer

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

    def chip_driven(self, pad):
        return self._chip(self.wires.get(pad, pad))[1]

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


# Bank 0 for sends, bank 1 for receives. Contention stress (direct port):
# MESH_RX_BASE=512 puts the receive region in bank 0 beside the sends (one
# single-port bank for reader, writer and host); MESH_STORM=1 adds a host
# that reads SRAM continuously, between the test's own accesses.
TX_BASE = 0
RX_BASE = int(os.environ.get('MESH_RX_BASE', 1024))
RX_CAPACITY = 512 if RX_BASE < 1024 else 1024
STORM = os.environ.get('MESH_STORM') == '1'


class DirectPort:
    """The host side on mesh_soc's own ports: SRAM through the memory's host
    port, the stream reader and writer, flags, events, parameters, and
    shifters' direct host ports. Every host action of a test goes through a
    port, so the same runner drives the chip through its pins (test_chip)."""

    def __init__(self, dut, vector, interface):
        self.dut, self.vector, self.interface = dut, vector, interface
        self.got = {name: [] for name, s in interface['streams'].items() if s['port'] == 'host'}
        self.lock = Lock()

    def bus(self, wires):
        return MeshBus(self.dut, wires)

    async def start(self):
        """Reset, configure, and wait until the mesh has loaded its tiles."""
        dut = self.dut
        dut.rst_n.value = 0; dut.run_req.value = 0; dut.mesh_hold.value = 0; dut.cfg.value = self.vector
        dut.pins.value = 0xff
        for sig in (dut.host_req, dut.host_we, dut.host_addr, dut.host_wdata, dut.rd_start, dut.rd_base, dut.rd_length,
                    dut.wr_start, dut.wr_base, dut.wr_length, dut.host_ev, dut.seen_clear, dut.param_we, dut.param_cell,
                    dut.param_addr, dut.param_data, dut.pk_pop):
            sig.value = 0
        await ClockCycles(dut.clk, 4)
        await FallingEdge(dut.clk); dut.rst_n.value = 1
        for _ in range(64):
            await RisingEdge(dut.clk)
            if int(dut.ready.value):
                return
        raise Failure('the mesh did not finish loading its configuration')

    def tasks(self):
        self.together = self.waited = self.storm_reads = 0
        return [self._collect(), self._contention()] + ([self._storm()] if STORM else [])

    async def _storm(self):
        """A host reading SRAM continuously in the receive region's bank."""
        while True:
            await self.mem(RX_BASE + RX_CAPACITY - 1 - self.storm_reads % 64)
            self.storm_reads += 1

    async def _contention(self):
        """Memory contention, measured on mesh_soc's request and grant wires:
        clocks with two or more of host, reader and writer requesting, and
        requests that waited (asked, not granted that clock)."""
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            await Timer(1, unit='ps')
            req = [int(dut.host_req.value) & int(dut.mem_en.value), int(dut.rq.value), int(dut.wq.value)]
            ready = int(dut.m_ready.value)
            self.together += sum(req) >= 2
            self.waited += sum(r and not ready >> i & 1 for i, r in enumerate(req))

    def summary(self):
        return (f'memory contention: {self.together} clocks with two or more requests, {self.waited} requests waited'
                + (f', {self.storm_reads} storm reads' if STORM else ''))

    async def _collect(self):
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
        async with self.lock:
            return await self._mem(addr, data)

    async def _mem(self, addr, data=None):
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
            v = dut.host_rdata.value
            return int(v) if v.is_resolvable else None     # a never-written location

    async def _strobe(self, **values):
        """Drive signals for one clock (from a falling edge), then zero them."""
        dut = self.dut
        await FallingEdge(dut.clk)
        for k, v in values.items():
            getattr(dut, k).value = v
        await FallingEdge(dut.clk)
        for k in values:
            getattr(dut, k).value = 0

    async def _pulse(self, sig, base_sig, base, len_sig, length):
        dut = self.dut
        await FallingEdge(dut.clk)
        base_sig.value = base; len_sig.value = length; sig.value = 1
        await FallingEdge(dut.clk); sig.value = 0

    async def open_writer(self, base, capacity):
        await self._pulse(self.dut.wr_start, self.dut.wr_base, base, self.dut.wr_length, capacity)

    async def run(self):
        await FallingEdge(self.dut.clk); self.dut.run_req.value = 1

    async def send(self, base, length):
        await self._pulse(self.dut.rd_start, self.dut.rd_base, base, self.dut.rd_length, length)

    async def reader_finished(self):
        return bool(int(self.dut.rd_done.value) or not int(self.dut.rd_active.value))

    async def written(self):
        return int(self.dut.wr_count.value)

    async def packet_head(self):
        """(end, err) of the oldest received packet in the region, or None."""
        if int(self.dut.pk_overflow.value):
            raise Failure('more than four received packets waited for the host (descriptor overflow)')
        if not int(self.dut.pk_count.value):
            return None
        return int(self.dut.pk_end.value), int(self.dut.pk_err.value)

    async def packet_pop(self):
        await self._strobe(pk_pop=1)

    async def flag(self, index):
        return int(self.dut.seen.value) >> index & 1

    async def clear(self):
        await self._strobe(seen_clear=1)

    async def fire(self, index):
        await self._strobe(host_ev=1 << index)

    async def param(self, cell, addr, value):
        await self._strobe(param_we=1, param_cell=cell, param_addr=addr, param_data=value & 0xffff)


async def until(dut, clock_ns, check, timeout):
    """Wait, a clock at a time, until `check()` holds; False after `timeout`
    clocks (a check that itself takes clocks, as a read over the chip's host
    link does, counts them)."""
    t0 = cocotb.utils.get_sim_time('ns')
    while True:
        await RisingEdge(dut.clk)
        if await check():
            return True
        if (cocotb.utils.get_sim_time('ns') - t0) / clock_ns > timeout:
            return False


async def call(dut, port, interface, step, delay, timeout, clock_ns):
    """Run one function call's host plan; returns its result bytes."""
    fn = interface['functions'][step['function']]
    args = step['args']
    start = await port.written()
    result = None
    for st in fn['steps']:
        if delay:
            await ClockCycles(dut.clk, delay)
        op = st['op']
        if op == 'clear':
            await port.clear()
        elif op == 'send':
            data = st['bytes'] if 'bytes' in st else args[st['arg']]
            # Never overwrite the region a previous call's stream still reads.
            if not await until(dut, clock_ns, port.reader_finished, timeout):
                raise Failure(f"line {step['line']}: {step['function']}: the previous stream never finished")
            for i, b in enumerate(data):
                await port.mem(TX_BASE + i, b)
            await port.send(TX_BASE, len(data))
        elif op == 'load':
            # One value into the transmit shifter: a byte through SRAM and the
            # reader (the shifter takes it when its transaction starts).
            await port.mem(TX_BASE, host_value(st['value'], args) & 0xff)
            await port.send(TX_BASE, 1)
        elif op == 'param':
            await port.param(st['cell'], st['addr'], host_value(st['value'], args))
        elif op == 'fire':
            await port.fire(st['index'])
        elif op in ('wait', 'wait_bytes'):
            n = host_value(st['count'], args) if op == 'wait_bytes' else None

            async def ready():
                return (await port.written() - start >= n) if n is not None else await port.flag(st['flag'])
            if not await until(dut, clock_ns, ready, timeout):
                what = f'{n} result bytes' if n is not None else st['signal']
                raise Failure(f"line {step['line']}: {step['function']}: no {what}")
        elif op == 'reply':
            n = await port.written() - start
            result = [await port.mem(RX_BASE + start + i) for i in range(n)]
            if 'mask' in st:
                result = [b & st['mask'] for b in result]
    return result


async def run_test(dut, port, interface, plan, test, delay=0):
    clock_ns = 1e9 / plan['clock_hz']
    clock = cocotb.start_soon(Clock(dut.clk, clock_ns, unit='ns').start())
    bus = port.bus(test['wires'])
    tasks = [cocotb.start_soon(bus.run())]
    try:
        await port.start()
        tasks += [cocotb.start_soon(t) for t in port.tasks()]
        if any(s['port'] == 'writer' for s in interface['streams'].values()) or \
                any(f.get('returns') == 'writer' for f in interface.get('functions', {}).values()):
            await port.open_writer(RX_BASE, RX_CAPACITY)
        # A stream write at the test's start is in place at time 0 in the
        # source's model: stage it (SRAM and the reader started) while the
        # mesh is still stopped, so a fabric event soon after `run` cannot
        # race the host link.
        staged = None
        first = test['steps'][0] if test['steps'] else None
        if first and first['op'] in ('write', 'write_packet') and 'stream' in first['target'] and \
                interface['streams'].get(first['target']['stream'], {}).get('port') == 'reader':
            for i, b in enumerate(first['bytes']):
                await port.mem(TX_BASE + i, b)
            await port.send(TX_BASE, len(first['bytes']))
            staged = first
        await port.run()
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
            # A packet write is one reader region: the reader tags its last
            # byte eop (mesh_soc), which ends a transmitter's packet burst.
            # Writes are armed, not awaited (the source's model: a stream
            # queues): a transmitter takes the bytes when its frames start
            # (an armed answer, an I2C read). A write waits for the previous
            # one to leave.
            if step['op'] in ('write', 'write_packet') and 'stream' in step['target']:
                name = step['target']['stream']
                if interface['streams'].get(name, {}).get('port') != 'reader':
                    raise Failure(f'line {line}: stream {name} is not a host -> mesh stream')
                if step is not staged:
                    if not await until(dut, clock_ns, port.reader_finished, timeout):
                        raise Failure(f'line {line}: stream {name}: the previous write never left')
                    for i, b in enumerate(step['bytes']):
                        await port.mem(TX_BASE + i, b)
                    await port.send(TX_BASE, len(step['bytes']))
                check_rules(line)
            elif step['op'] == 'read' and 'stream' in step['target']:
                name = step['target']['stream']
                start = consumed.get(name, 0)
                via_sram = interface['streams'][name]['port'] == 'writer'

                async def have():
                    return await port.written() if via_sram else len(port.got[name])

                async def enough():
                    return await have() - start >= step['count']
                if not await until(dut, clock_ns, enough, timeout):
                    raise Failure(f"line {line}: stream {name} received {await have() - start} of {step['count']} bytes")
                if via_sram:
                    got = [await port.mem(RX_BASE + start + i) for i in range(step['count'])]
                else:
                    got = port.got[name][start:start + step['count']]
                consumed[name] = start + step['count']
                if got != step['expect']:
                    raise Failure(f"line {line}: {name}.read({step['count']}) returned {fmt(got)}, expected {fmt(step['expect'])}")
                check_rules(line)
            elif step['op'] == 'read_packet' and 'stream' in step['target']:
                name = step['target']['stream']
                if interface['streams'][name]['port'] != 'writer':
                    raise Failure(f'line {line}: packet reads come through the writer (stream {name})')
                start = consumed.get(name, 0)

                async def head():
                    return await port.packet_head() is not None
                if not await until(dut, clock_ns, head, timeout):
                    raise Failure(f'line {line}: stream {name}: no packet arrived')
                end, err = await port.packet_head()
                async def stored():
                    return await port.written() >= end
                await until(dut, clock_ns, stored, timeout)
                got = {'data': [await port.mem(RX_BASE + i) for i in range(start, end)], 'error': bool(err)}
                await port.packet_pop()
                consumed[name] = end
                want = {'data': step['expect']['data'], 'error': bool(step['expect']['error'])}
                if got != want:
                    raise Failure(f"line {line}: {name}.read_packet() returned {fmt(got['data'])} error {got['error']:d}, "
                                  f"expected {fmt(want['data'])} error {want['error']:d}")
                check_rules(line)
            elif step['op'] == 'read' and 'peer' in step['target']:
                peer = attached[step['target']['peer']]

                async def arrived():
                    return len(peer.received) >= step['count']
                await until(dut, clock_ns, arrived, timeout)
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
                got = await call(dut, port, interface, step, delay, timeout, clock_ns)
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
        if hasattr(port, 'summary'):
            dut._log.info('%s', port.summary())
        for peer in attached.values():
            if hasattr(peer, 'finish'):
                peer.finish()
    finally:
        for task in tasks:
            task.cancel()
        clock.cancel()


def load(stem):
    """A compiled program: its configuration vector, interface and plan."""
    words = [int(x, 16) for x in Path(stem + '.hex').read_text().split()]
    vector = sum(w << (32 * i) for i, w in enumerate(words))
    return vector, json.loads(Path(stem + '.mesh.json').read_text()), json.loads(Path(stem + '.plan.json').read_text())


async def run_program(dut, stem, make_port, host_delay=True):
    """Every test of one program (twice with host delay if it has functions
    and host_delay); returns the failures."""
    vector, interface, plan = load(stem)
    failures = []
    delays = [0, HOST_DELAY] if interface.get('functions') and host_delay else [0]
    for test in plan['tests']:
        for delay in delays:
            tag = f' (host delay {delay})' if delay else ''
            try:
                await run_test(dut, make_port(dut, vector, interface), interface, plan, test, delay)
                dut._log.info('%s: test "%s" passed%s', Path(stem).name, test['name'], tag)
            except Failure as error:
                failures.append(f"{Path(stem).name} \"{test['name']}\"{tag}: {error}")
                dut._log.error('%s: test "%s" failed%s: %s', Path(stem).name, test['name'], tag, error)
    return failures


@cocotb.test()
async def mesh_compiled_program(dut):
    failures = await run_program(dut, os.environ['MESH'], DirectPort)
    assert not failures, failures
