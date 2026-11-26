#!/usr/bin/env python3
"""Protocol mapping census data (see PROTOCOL_CENSUS.md).

Run to print status totals, gap counts and pattern use; pass a path to
write the census tables as Markdown.
"""
# Census data: protocol -> (set, pins "out/in/bidir", patterns, grid status, blocking gaps, note)
# status: R runs at pins today, M mappable on current hardware (compiler lowering only),
#         W works only with a workaround (host-assisted, multiplexed uo[0] pin), B blocked by missing hardware.
P = [
 # inherited pin tests (arch/spatial lineage, PX8 + fabric)
 ("UART 8N1",          "inh", "1/1/0", "T S F Y D",       "R", [], "compiled uart.spt streams"),
 ("SPI controller",    "inh", "3/1/0", "T S F Q D",       "W", ["pins"], "CS on multiplexed uo[0]"),
 ("SPI target",        "inh", "1/3/0", "S F M Q R D",     "B", ["pins","match"], "input clock, command decode, MISO before next edge"),
 ("I2C controller",    "inh", "0/0/2", "T S F Q B D",     "R", [], "write_read, NACK, stretch"),
 ("I2C target",        "inh", "0/0/2", "S F M Q R D",     "B", ["match"], "7-bit address match, ACK in window"),
 ("JTAG TAP",          "inh", "3/1/0", "T S F Q D",       "W", ["pins"], "TMS on multiplexed uo[0]"),
 ("SWD host",          "inh", "1/0/1", "T S F P M Q R D", "B", ["parity","match"], "33-bit data+parity, 3-bit ACK, turnaround"),
 ("PS/2 device RX",    "inh", "0/2/0", "S F P D",         "W", ["parity"], "host checks odd parity"),
 ("PS/2 host",         "inh", "0/0/2", "T S F P Q R D",   "W", ["parity"], "host packs parity; RTS hold"),
 ("1-Wire master",     "inh", "0/0/1", "T S Q D",         "M", [], "timed slots; ROM search via host"),
 ("WS2812",            "inh", "1/0/0", "T L D",           "M", [], "bit selects high time: 2 timers + LUT"),
 ("DMX512",            "inh", "1/0/0", "T F D",           "M", [], "break/MAB + 8N2"),
 ("CAN TX",            "inh", "1/1/0", "T F L C A Q D",   "M", [], "coder stuffing, CRC-15, arbitration via LUT xor"),
 ("CAN RX",            "inh", "1/1/0", "S F L C M R Q D", "B", ["rxcode","match"], "resync, destuff, CRC check, ACK slot"),
 ("HDLC (sync)",       "inh", "1/2/0", "S F L C M D",     "B", ["rxcode","match"], "flag 0x7E detect, zero-destuff, CRC-16"),
 ("I2S TX",            "inh", "3/0/0", "T F D",           "W", ["pins"], "BCLK, WS, SD: third on uo[0]"),
 ("USB LS TX",         "inh", "0/0/2", "T F L C Q D",     "R", [], "coded stream, NRZI, stuffing, CRC16, EOP"),
 ("USB LS RX",         "inh", "0/0/2", "S F L C M R Q D", "B", ["rxcode","match"], "clock recovery, SYNC/PID match, handshake window"),
 ("10BASE-T TX",       "inh", "2/0/0", "T F L C Q D",     "R", [], "session: NLP, Manchester, FCS, TP_IDL"),
 ("Quadrature",        "inh", "0/2/0", "S Q K D",         "M", [], "4-state FSM in LUTs; host keeps count"),
 ("VGA",               "inh", "3/0/0", "T K D",           "W", ["pins"], "hsync, vsync, 1-bit colour; third on uo[0]"),
 ("GPIO expander",     "inh", "4/1/0", "T F D",           "B", ["pins"], "74HC595 + 74HC165 chain"),
 # held-out classes (written from public specs; not the oracle)
 ("MDIO",              "held", "1/0/1", "T F Q D",        "M", [], "two 16-bit frames, turnaround"),
 ("Modbus RTU master", "held", "1/1/0", "T F C X D",      "M", [], "CRC-16 tile; 3.5-char gap by timer restart"),
 ("Modbus RTU slave",  "held", "1/1/0", "T F C X M R D",  "B", ["match"], "address match, reply window"),
 ("LIN master",        "held", "1/1/0", "T F P K D",      "W", ["parity","checksum"], "PID parity, additive checksum by host"),
 ("LIN slave",         "held", "1/1/0", "S F P K X M D",  "B", ["capture","match","checksum"], "autobaud on 0x55, PID match"),
 ("SMBus + PEC",       "held", "0/0/2", "T S F C Q B X D","M", [], "I2C + CRC-8 tile + timeout"),
 ("SD card (SPI mode)","held", "3/1/0", "T S F C M Q D",  "B", ["pins","match"], "CRC7, poll R1 != 0xFF, token 0xFE"),
 ("NEC IR TX",         "held", "1/0/0", "T L D",          "M", [], "38 kHz carrier AND burst, pulse distance"),
 ("NEC IR RX",         "held", "0/1/0", "S X F D",        "M", [], "timer level sampled at edge = bit"),
 ("SENT TX",           "held", "1/0/0", "T L C D",        "B", ["duration"], "nibble = 12..27 ticks: duration from data"),
 ("Wiegand",           "held", "2/0/0", "T Q D",          "M", [], "bit selects D0/D1 pulse: LUT"),
 ("MIDI",              "held", "1/1/0", "T S F D",        "M", [], "UART at 31250"),
 ("CAN FD TX",         "held", "1/1/0", "T F L C A Q D",  "B", ["paramctx"], "bit-rate switch mid-frame"),
 ("I3C SDR controller","held", "0/0/2", "T S F P Q B D",  "B", ["paramctx","parity"], "push-pull/open-drain switch, T-bit"),
]
PAT = dict(T="timed waveform", S="sample/sync", F="serialize field", L="line code", C="check (CRC)",
           P="parity", K="count/state variable", M="match value", Q="sequence/branch", R="respond in window",
           A="arbitrate", B="peer clock stretch", X="measure interval/timeout", Y="full duplex", D="host stream")
GAP = dict(pins="more than 2 pads + 1 input + multiplexed uo[0]",
           match="value/pattern match on received bits",
           rxcode="receive line decode + clock recovery in the grid",
           parity="parity generate/check in the frame engine",
           checksum="additive checksum",
           capture="interval capture",
           duration="duration taken from data",
           paramctx="tile-parameter contexts")
import collections, sys
def counts(rows):
    c=collections.Counter(s for *_,s,_,_ in [(r[0],r[4],r[5],r[6]) for r in rows])
    return c
for name,sel in (("inherited","inh"),("held-out","held"),("all",None)):
    rows=[r for r in P if sel is None or r[1]==sel]
    st=collections.Counter(r[4] for r in rows)
    print(name,len(rows),dict(st))
blk=collections.Counter(); wk=collections.Counter(); solo=collections.Counter()
for r in P:
    for g in r[5]:
        (blk if r[4]=="B" else wk)[g]+=1
    if r[4]=="B" and len(r[5])==1: solo[r[5][0]]+=1
print("blocked-by", dict(blk)); print("workaround-by", dict(wk)); print("sole blocker", dict(solo))
pc=collections.Counter(p for r in P for p in r[3].split())
print("pattern use", {PAT[k]:v for k,v in pc.most_common()})

def table(sel):
    out=["| Protocol | Pins out/in/bidir | Patterns | Grid today | Missing hardware | Note |","|---|---|---|---|---|---|"]
    name={"R":"runs at pins","M":"mappable (compiler only)","W":"workaround","B":"**blocked**"}
    for r in P:
        if r[1]!=sel: continue
        out.append(f"| {r[0]} | {r[2]} | {r[3]} | {name[r[4]]} | {', '.join(r[5]) or '-'} | {r[6]} |")
    return "\n".join(out)
if len(sys.argv)>1:
    open(sys.argv[1],"w").write(table("inh")+"\n\n@@HELD@@\n\n"+table("held")+"\n")
