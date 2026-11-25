"""Credit-reader/coder integration against independent USB and Ethernet models."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb_tests.line_codes import USB_SYNC, crc16_usb, ethernet_fcs, lsb_bits, usb_encode
from cocotb_tests.test_ethernet import test_frame
from cocotb_tests.test_usb import TX_CASES


@cocotb.test()
async def packet_streams(dut):
    cocotb.start_soon(Clock(dut.clk, 25, unit='ns').start())
    dut.rst_n.value=0;dut.enable.value=0;dut.start.value=0;dut.tick.value=0
    dut.shift_cfg_we.value=0;dut.crc_cfg_we.value=0
    dut.mem_ready.value=0;dut.mem_rvalid.value=0;dut.mem_rdata.value=0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk);dut.rst_n.value=1

    async def write(which, addr, value):
        await FallingEdge(dut.clk)
        getattr(dut,which+'_cfg_addr').value=addr
        getattr(dut,which+'_cfg_data').value=value
        getattr(dut,which+'_cfg_we').value=1
        await FallingEdge(dut.clk);getattr(dut,which+'_cfg_we').value=0

    async def run(payload, ethernet, starve=False):
        await FallingEdge(dut.clk);dut.enable.value=0;dut.tick.value=0
        for addr,value in [(1,7),(2,1),(3,1<<11),(4,(1<<5)|(1<<6)),
                           (5,((1<<15)|(32<<9)) if ethernet else (6|(1<<3)|(1<<4)|(16<<9))),
                           (6,(64 if ethernet else 16)<<6)]:
            await write('shift',addr,value)
        poly=0x04C11DB7 if ethernet else 0x8005
        for addr,value in [(0,poly&65535),(1,poly>>16),(2,0),(3,0),(4,0),(5,0),
                           (6,(31 if ethernet else 15)|0x60),(7,0)]:
            await write('crc',addr,value)
        await FallingEdge(dut.clk);dut.enable.value=1;dut.base.value=0;dut.length.value=len(payload);dut.start.value=1
        await FallingEdge(dut.clk);dut.start.value=0
        pending=[];observed=[];accepted=0;period=2 if ethernet else 33
        for cycle in range(40000):
            # Registered 3-cycle responses and deterministic bank contention.
            await FallingEdge(dut.clk)
            dut.tick.value=int(cycle%period==0)
            dut.mem_ready.value=int(cycle%4 != 0 and (not starve or accepted==0 or cycle>=120))
            response = pending.pop(0) if pending and pending[0][0]==cycle else None
            dut.mem_rvalid.value=int(response is not None)
            dut.mem_rdata.value=response[1] if response else 0
            await Timer(1,unit='ns')
            request = bool(int(dut.mem_req.value)) and bool(int(dut.mem_ready.value))
            address = int(dut.mem_addr.value)
            if cycle%period==0 and int(dut.active.value) and int(dut.consumed.value)>0:
                observed.append(int(dut.serial.value))
            await RisingEdge(dut.clk)
            if request:
                assert address < len(payload);pending.append((cycle+3,payload[address]));accepted+=1
            await Timer(1,unit='ns')
            if int(dut.done.value):
                if starve:
                    assert int(dut.error.value), 'underrun must be reported'
                    return observed
                assert not int(dut.error.value), 'stream underrun or memory failure'
                assert accepted==len(payload) and int(dut.consumed.value)==len(payload)
                break
        else: assert False,'coded packet did not complete'
        return observed

    payload=TX_CASES['stuffing_mix'];packet=bytes([USB_SYNC,0xC3])+payload
    observed=await run(packet,False)
    expected=[int(s=='K') for s in usb_encode(packet+crc16_usb(payload).to_bytes(2,'little'))[:-3]]
    assert observed==expected,(len(observed),len(expected),next((i for i,(a,b) in enumerate(zip(observed,expected)) if a!=b),None))
    frame=test_frame();preamble=bytes([0x55]*7+[0xD5])
    observed=await run(preamble+frame,True)
    bits=lsb_bits(preamble+frame+ethernet_fcs(frame))
    expected=[half for bit in bits for half in (1-bit,bit)]
    assert observed==expected,(len(observed),len(expected),next((i for i,(a,b) in enumerate(zip(observed,expected)) if a!=b),None))

    await run(preamble+frame,True,starve=True)  # deliberate FIFO starvation must fail closed
