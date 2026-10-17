# Controller (PX8)

## What it does

The PX8 is a tiny processor. It runs the program stored in SRAM. Its jobs:

1. **Load configurations** into the tiles.
2. **Arm** the fabric.
3. **Wait for events** and **decide what comes next**: for example, which
   I2C byte to send next, or whether a checksum passed.
4. **Move data:** for example, stream a stored Ethernet frame into a TX
   FIFO.

What it **does not** do: it has no instruction to drive a pin and no
instruction to wait a fixed number of cycles. Every pin is driven by the
fabric, and every bit time comes from a timer. So no bit's timing ever
depends on software.

## Instructions

Every instruction is one byte: a 4-bit opcode and a 4-bit operand `n`.
Bigger numbers are built with prefix bytes: `PFIX` shifts 4 more bits into
the operand. The assembler adds prefixes automatically.

Registers:

- `A`: the accumulator.
- `C`: a counter.
- `P`: a pointer into SRAM data.

| Op | Name | Effect |
| --- | --- | --- |
| 0 | `PFIX` | build a bigger operand |
| 1 | `LDC` | `A = operand` |
| 2 | `SETP` | `P = operand` |
| 3 | `XRC` | `A = A xor operand` |
| 4 | `J` | jump |
| 5 | `JZ` | jump if `A == 0` |
| 6 | `DJNZ` | `C = C − 1`; jump if `C != 0` |
| 7 | `SETC` | `C = operand` |
| 8 | `WCF` | write `A` to configuration address `operand` |
| 9 | `RD` | read a status value into `A` (table below) |
| A | `WEV` | wait for line `operand` (or byte-tile event `64 + t`) |
| B | `FIRE` | pulse line 2 or 3 |
| C, D | — | reserved (do nothing) |
| E | `OPR` | one of the operations below |
| F | `ANDC` | `A = A and operand` |

`OPR` operations:

| Code | Name | Effect |
| --- | --- | --- |
| 0 | `NOP` | nothing |
| 1 | `HALT` | stop the program |
| 2 | `PULL` | take a byte from a TX FIFO into `A` (tags in `A[9:8]`) |
| 3 | `PUSH` | put `A`'s byte into an RX FIFO |
| 4 | `CLREV` | clear remembered events |
| 5, 6 | | `A = C`, `C = A` |
| 7 | `TXP` | put `A`'s byte into a TX FIFO |
| 8 | `LDM` | `A = SRAM[P]`, then `P = P + 1` |
| 9 | `CFG` | load `C` configuration words from SRAM at `P` |

For `PULL`, `PUSH` and `TXP`, operand bit 4 picks the FIFO channel; for
`PUSH` and `TXP`, bit 5 tags the byte *eop* and bit 6 tags it *err*.

## Things worth knowing

- **Speed:** most instructions take 2 cycles.
- **Fast setup:** `CFG` loads one configuration word every 3 cycles from a
  table in SRAM. The assembler builds these tables automatically.
- **Events are remembered:** a pulse line that fires while the program is
  busy is remembered until `WEV` sees it. Level lines are seen one cycle
  late.
- **FIFO ownership:** a shifter that auto-pulls owns its TX FIFO; the
  controller only pulls from channels no shifter is using.

## Status values for `RD`

| Address | Value |
| --- | --- |
| 0 | pin levels |
| 1, 3 | shifter 0 / 1 received word |
| 2, 4 | shifter 0 / 1 status |
| 5, 6 | counter 0 / 1 count |
| 7, 8 | CRC low / high 16 bits |
| 9, 10 | remembered events |

## Special configuration addresses

| Address | Meaning |
| --- | --- |
| `0x30` | controller flags `[1:0]` (lines 54, 55) |
| `0x31` | arm the fabric |
| `0x34`, `0x35` | [contexts](contexts.md): select line, which contexts writes go to |

Next: [Host link](host-link.md).
