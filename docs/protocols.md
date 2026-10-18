# Protocols

Every protocol below is a program in
`test/cocotb_tests/protocols.py`. None of them is special hardware. Each is
tested through the chip's pins only, against a separate reference model of
the device on the other end. Some are also proven: `make -C formal
uart_tx ws2812` runs the whole core on the same program bytes against a
symbolic stream of FIFO bytes (see [Verification](verification.md)).

## Required by the competition

| Protocol | What is tested |
| --- | --- |
| **UART** 8N1, full duplex | every edge exactly one bit period; send and receive at the same time |
| **UART** two transmitters | each shifter sends its own byte stream at its own speed |
| **UART** 8E1 errors | a wrong parity bit or stop bit arrives tagged *err* |
| **SPI** master, modes 0–3 | bytes both ways against a reference device; chip-select timing |
| **I2C** master | write, repeated start, read, ACK/NACK, clock stretching (including during start and stop) |

## Stretch goals

| Protocol | What is tested |
| --- | --- |
| **USB low speed** send | NRZI, bit stuffing (also inside the checksum), CRC16, end of packet; every edge on the bit grid; empty, 1-byte and 8-byte payloads |
| **USB low speed** receive | recovers the sender's clock (3% fast or slow, or jittery); removes stuffed bits; checks CRC16; detects a bad CRC |
| **10BASE-T** send (40 MHz clock) | link pulses exactly 100 ns wide and 16 ms apart; frames of 46 to 400 payload bytes with exact 2-cycle half bits; the checksum equals `zlib.crc32` |
| **10BASE-T** receive (40 MHz clock) | frames recovered bit-exact; a bad checksum tagged *err*; back-to-back frames; link pulses ignored |

## Others

| Protocol | What is tested |
| --- | --- |
| **PS/2** receive | 11-bit frames with odd parity, clocked by the device |
| **PS/2** host | commands to a keyboard model (reset, set LEDs) with its ACKs and replies on the same two open-drain lines; every clock inhibit exactly 100 us (scaled) |
| **CAN 2.0A** receive (node) | on a wired-AND bus with a reference transmitter: clock recovery on every dominant edge, destuffing, frames recovered bit-exact, CRC-15 checked in the fabric; good frames acknowledged for exactly their ACK slot, a bad one tagged *err* and not acknowledged; the whole fabric is one CAN node |
| **CAN 2.0A** send | stuff bits after five equal bits, in the header, data and CRC-15, matching a reference bit for bit; every edge on the bit grid; random identifiers and 0–8 byte payloads |
| **JTAG** master | TMS/TDI change only while TCK is low; against a full IEEE 1149.1 TAP state machine: IDCODE read, IR write, user register write and read back |
| **SWD** host | line reset, JTAG-to-SWD switch, DP IDCODE read with ACK and parity, a SELECT write, a read back; turnarounds with no bus contention |
| **1-Wire** master | reset and presence, ROM read with CRC-8, scratchpad write and read against a DS18B20-style device; every low pulse exactly 6, 60 or 480 us; no device answers presence 1 |
| **I2C** slave | against a reference master: writes acknowledged byte by byte; a foreign address never acknowledged or driven; a register write, repeated START and read ending in NACK and STOP; SDA never moves while SCL is high |
| **SPI** slave, mode 0 | 1- to 3-byte transactions both ways from a reference master; MISO driven only while chip select is low |
| **I2S** send | 16- and 24-bit stereo against a reference receiver; exact BCLK half periods; SD and WS move only while BCLK is low |
| **WS2812 (NeoPixel)** | every bit period 1.25 us and every high time 0.4 / 0.8 us exactly, across a gapless strip |
| **DMX512** send | break >= 88 us, mark after break >= 8 us, every 8N2 slot on the bit grid; two packets |
| **Async HDLC / PPP** over UART | escape bytes and delimiters on the wire; checksum added and checked |
| **SLIP** over UART | the same tiles, set up differently |
| **Modbus-RTU style** | packets separated only by quiet time; only packets for our address kept |
| **Packet bursts** | each host packet becomes exactly one frame on the wire |
| **Error injection** | a packet marked *err* is sent with a wrong checksum, and the receiver catches it |
| **Contexts** | a pin or the fabric itself switches settings in one step (see [Contexts](contexts.md)) |

## Two examples, explained

### USB send

USB low speed adds two tricks on top of plain bits:

- **NRZI:** a 0 bit flips the line, a 1 bit leaves it alone.
- **Bit stuffing:** after six 1s in a row, an extra 0 is inserted.

On the chip:

1. **Timer 0** ticks once per bit.
2. **Counter 0** counts 1s in a row; at 6, the next bit is a stuffed 0.
3. **Logic cells** choose each bit: the stuffed 0, the shifter's next bit,
   or the CRC's next bit once the data runs out. Another logic cell applies
   NRZI and drives the two USB pins.
4. **The CRC engine** absorbs the data bits, then shifts out the checksum.
5. **The controller** only says "now end the packet". A logic cell applies
   that at the next bit, never in place of a stuffed bit.

### 10BASE-T receive

10BASE-T uses Manchester code: every bit has a transition in its middle. A
1 goes low then high.

1. **Logic cells** spot transitions on the receive pin.
2. **A timer** opens a short window so that only the mid-bit transition is
   used. The preamble (`1010…`) locks this up automatically.
3. **A counter** spots the `11` that ends the preamble. From there the
   shifter collects bytes.
4. **The CRC engine** checks the whole frame.
5. **A second timer** notices when the signal stops. That ends the packet
   in the byte layer, tags *err* if the CRC failed, and drops any
   half-received byte.

## Limits of the 10BASE-T support

- **Outside the chip:** needs a line driver, a transformer and a receive
  comparator (see [hardware.md](hardware.md)).
- **Not a certified PHY:** this is a hobby-grade link.
- **Host speed on receive:** the host must read a byte at least every 32
  cycles (the board's RP2040 can, using its PIO block).

Next: [Verification](verification.md).
