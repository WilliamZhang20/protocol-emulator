"""Chip-pin experiment for an SRAM-fed coded Ethernet digital frame."""
from pathlib import Path
import os
import json
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer
from cocotb_tests.line_codes import ethernet_fcs, lsb_bits

@cocotb.test()
async def ethernet_manchester_frame(dut):
    cocotb.start_soon(Clock(dut.clk,25,unit='ns').start())
    dut.ena.value=1;dut.rst_n.value=0;dut.ui_in.value=0
    state={'op':0,'strobe':0}
    def drive():dut.uio_in.value=(state['op']<<2)|(state['strobe']<<1)|1
    drive();await ClockCycles(dut.clk,8)
    await FallingEdge(dut.clk);dut.rst_n.value=1
    await ClockCycles(dut.clk,8)
    async def command(op,data):
        await FallingEdge(dut.clk);dut.ui_in.value=data;state['op']=op;state['strobe']=0;drive()
        await ClockCycles(dut.clk,4)
        await FallingEdge(dut.clk);state['strobe']=1;drive()
        await ClockCycles(dut.clk,5)
        await FallingEdge(dut.clk);state['strobe']=0;drive()
        await ClockCycles(dut.clk,4)
    async def config(i,w):
        await command(0,i);await command(6,w&255);await command(7,w>>8)
    async def write_byte(addr,value):
        await command(0,addr&255);await command(1,addr>>8);await command(2,value)
    root=Path(__file__).parents[1]/'data'
    image=[int(x,16) for x in Path(os.environ.get('CODED_IMAGE',root/'grid-ethernet-coded.mem')).read_text().splitlines()]
    program=json.loads(Path(os.environ.get('CODED_PROGRAM',root/'grid-ethernet-coded.json')).read_text())
    payload=bytes(program['payload_bytes']);frame=payload[8:]
    assert len(image)==124 and image[66]==len(payload)
    await command(4,8)
    for index,word in enumerate(image):await config(index,word)
    await command(4,0);await command(4,4)
    assert int(dut.uio_oe.value)&0x80,'coded stream did not arm'
    assert (int(dut.uio_out.value)&0x60)==0,'Ethernet outputs must be quiet before transmit'
    for i,byte in enumerate(payload):await write_byte(100+i,byte)
    bits=lsb_bits(payload+ethernet_fcs(frame));expected=[x for b in bits for x in (1-b,b)]
    async def monitor():
        samples=[]
        for _ in range(8000):
            await FallingEdge(dut.clk);await Timer(1,unit='ns')
            pins=int(dut.uio_out.value);oe=int(dut.uio_oe.value)
            samples.append(((pins>>6)&1,(pins>>5)&1,oe))
            if pins&0x80:return samples
        assert False,'packet did not finish'
    async def contend():
        # The host and packet reader share SRAM0. These writes are outside
        # the packet buffer and occur while the 10 Mb/s stream is active.
        for i in range(20):
            await write_byte(600+i,(i*37)&255)
    for _ in range(2):
        task=cocotb.start_soon(monitor());await command(5,0)
        traffic=cocotb.start_soon(contend())
        samples=await task;await traffic
        observed=[p for p,n,oe in samples]
        found=[]
        for offset in range(min(100,len(observed))):
            seq=observed[offset:offset+2*len(expected):2]
            if seq==expected and observed[offset:offset+2*len(expected)]==[v for x in expected for v in (x,x)]:found.append(offset)
        assert found,('no exact Manchester/FCS stream',len(samples),len(expected),observed[:80],expected[:40])
        offset=found[0]
        assert all(n==1-p and (oe&0x60)==0x60 for p,n,oe in samples[offset:offset+2*len(expected)])
        assert samples[-1][0:2]==(0,0),'Ethernet outputs must return to quiet after transmit'
        state['op']=4;state['strobe']=0;drive();await ClockCycles(dut.clk,5);await FallingEdge(dut.clk)
        assert not (int(dut.uo_out.value)&0x40),'packet engine reported underrun/error'
    dut._log.info('Ethernet preamble, frame and FCS transmitted in %d Manchester half-bits',len(expected))

async def run_usb_data_packet(dut, image_file, program_file):
    from cocotb_tests.line_codes import crc16_usb,usb_encode
    cocotb.start_soon(Clock(dut.clk,20,unit='ns').start())
    dut.ena.value=1;dut.rst_n.value=0;dut.ui_in.value=0
    state={'op':0,'strobe':0}
    def drive():dut.uio_in.value=(state['op']<<2)|(state['strobe']<<1)|1
    drive();await ClockCycles(dut.clk,8)
    await FallingEdge(dut.clk);dut.rst_n.value=1
    await ClockCycles(dut.clk,8)
    async def command(op,data):
        await FallingEdge(dut.clk);dut.ui_in.value=data;state['op']=op;state['strobe']=0;drive()
        await ClockCycles(dut.clk,4)
        await FallingEdge(dut.clk);state['strobe']=1;drive()
        await ClockCycles(dut.clk,5)
        await FallingEdge(dut.clk);state['strobe']=0;drive()
        await ClockCycles(dut.clk,4)
    async def config(i,w):
        await command(0,i);await command(6,w&255);await command(7,w>>8)
    async def write_byte(addr,value):
        await command(0,addr&255);await command(1,addr>>8);await command(2,value)
    root=Path(__file__).parents[1]/'data'
    image=[int(x,16) for x in Path(os.environ.get('USB_CODED_IMAGE',root/image_file)).read_text().splitlines()]
    program=json.loads(Path(os.environ.get('USB_CODED_PROGRAM',root/program_file)).read_text())
    packet=bytes(program['payload_bytes']);data=packet[2:]
    assert len(image)==124 and image[66]==len(packet)
    await command(4,8)
    for index,word in enumerate(image):await config(index,word)
    # A configured CRC tail without its direct coder link must fail closed.
    await config(75,image[75]&~0x40)
    await command(4,0);await command(4,4)
    assert not (int(dut.uio_oe.value)&0x80),'unlinked CRC tail armed'
    await command(4,0);await command(4,8);await config(75,image[75])
    await command(4,0);await command(4,4)
    assert int(dut.uio_oe.value)&0x80,'coded temporal configuration did not arm'
    async def monitor():
        samples=[]
        for _ in range(15000):
            await FallingEdge(dut.clk);await Timer(1,unit='ns')
            pins=int(dut.uio_out.value);oe=int(dut.uio_oe.value)
            dp=(pins>>6)&1;dm=(pins>>5)&1
            samples.append(('Z' if oe&0x60!=0x60 else ('K' if dp and not dm else 'J' if dm and not dp else 'SE0' if not dp and not dm else 'SE1')))
            if pins&0x80:return samples,oe
        assert False,'USB packet did not finish'
    packets=[packet]
    if len(data)==8:
        # Same configured byte length, host replaces SRAM contents at runtime.
        packets += [packet[:2]+bytes(8), packet[:2]+bytes([0x55,0xaa]*4)]
    for current in packets:
        for i,byte in enumerate(current):await write_byte(100+i,byte)
        expected=usb_encode(current+crc16_usb(current[2:]).to_bytes(2,'little'))
        for _ in range(2):
            task=cocotb.start_soon(monitor());await command(5,0);samples,oe=await task
            found=[]
            for offset in range(min(200,len(samples))):
                if (samples[offset:offset+33*len(expected):33]==expected and
                    all(len(samples[offset+i*33+3:offset+(i+1)*33-3])==27 and
                        all(x==symbol for x in samples[offset+i*33+3:offset+(i+1)*33-3])
                        for i,symbol in enumerate(expected))):found.append(offset)
            if not found:
                runs=[]
                for x in samples:
                    if runs and runs[-1][0]==x:runs[-1][1]+=1
                    else:runs.append([x,1])
                dut._log.info('USB observed runs: %s',runs)
            assert found,('USB waveform mismatch',len(samples),len(expected))
            assert oe&0x60==0,'bus not released after EOP'
            state['op']=4;state['strobe']=0;drive();await ClockCycles(dut.clk,5);await FallingEdge(dut.clk)
            assert not (int(dut.uo_out.value)&0x40),'packet engine reported underrun/error'
    dut._log.info('USB low-speed DATA0 packet, CRC, stuffing and EOP sent across chip pins')


@cocotb.test()
async def usb_low_speed_data_packet(dut):
    await run_usb_data_packet(dut, 'grid-usb-coded.mem', 'grid-usb-coded.json')


@cocotb.test()
async def usb_low_speed_empty_packet(dut):
    await run_usb_data_packet(dut, 'grid-usb-empty.mem', 'grid-usb-empty.json')


@cocotb.test()
async def usb_low_speed_max_packet(dut):
    await run_usb_data_packet(dut, 'grid-usb-max.mem', 'grid-usb-max.json')
