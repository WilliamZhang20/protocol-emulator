# Host link

The board's microcontroller (the *host*) talks to the chip through 8 input
pins (`ui_in`) and 8 output pins (`uo_out`).

## How a command works

1. The host puts a **command byte** on `ui_in`: the top 4 bits are the
   command, the bottom 4 bits a small value (the *payload*).
2. It holds the byte for **at least 2 clock cycles**.
3. It then puts `0x00` on the pins for at least 2 cycles, which means
   "ready for the next command".
4. If the command returns something, it appears on `uo_out`.

A byte only counts once it has been steady for 2 cycles, so a byte caught
while the pins are changing is ignored. Bytes are sent as two halves (low
nibble, then high nibble).

## Commands

**Commands that change something** (`uo_out` keeps its last answer):

| Cmd | What it does |
| --- | --- |
| `1`, `2`, `3` | set SRAM address bits 3:0, 7:4, 9:8 |
| `4` then `5` | write a byte to SRAM (low half, then high half); the address then goes up by 1 |
| `6` then `7` | push a byte into the TX FIFO (low half, then high half) |
| `6` then `F` | same, and tag the byte *end of packet* |
| `8` | payload bit 0: start the chip; bit 1: stop it |
| `E` | pick FIFO channel 0 or 1 (payload bit 0) |

**Commands that answer on `uo_out`:**

| Cmd | Answer |
| --- | --- |
| `9` | the next received byte, removing it from the RX FIFO |
| `A` | status: `{running, halted, tx_full, rx_empty, 0, 0, eop, err}`, where eop and err are the tags of the next received byte |
| `B` | the SRAM byte at the current address (only while stopped) |
| `C` | FIFO fill levels `{tx_full, rx_empty, tx_level[2:0], rx_level[2:0]}` |
| `D` | the next received byte, without removing it |

Notes:

- **Channel:** FIFO commands use the channel picked with `E` (channel 0
  after reset).
- **When the program halts,** the host clears the running bit, and every
  tile and pin goes idle.

See [External hardware](hardware.md) for pins and clocks.

Next: [Protocols](protocols.md).
