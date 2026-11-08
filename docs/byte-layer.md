# Byte layer

## What it is for

The [bit fabric](tiles.md) is good at bits and timing. Some protocols also
need work on whole bytes:

- **escaping special bytes:** HDLC and SLIP replace their "end of packet"
  byte when it appears inside the data;
- **finding where a packet ends:** a special byte, or a quiet gap on the
  line;
- **checksums:** adding up all the bytes of a packet;
- **filtering:** keeping only packets addressed to us.

The byte layer does this in hardware, between each shifter and its FIFOs.

## Tags

Every byte carries two extra bits, called **tags**:

- **eop** (end of packet): this is the last byte of a packet.
- **err** (error): something is wrong with this packet. On the receive side
  it means "error found"; on the send side it means "send this wrongly on
  purpose" (to test the other device).

The FIFOs store the tags with each byte. The host and the controller can
both see and set them (see [Host link](host-link.md) and
[Controller](controller.md)).

## Where the byte tiles sit

Each FIFO channel has 4 byte tiles, 2 per direction:

```text
send:     TX FIFO → stage 0 → stage 1 → shifter → pins
receive:  pins → shifter → stage 0 → stage 1 → RX FIFO
```

All 8 tiles are the same. Each can do any of the jobs below, so the order
of operations is chosen by configuration. After reset every tile is in
`PASS` mode, which changes nothing.

## What a byte tile can do

| Mode | What it does |
| --- | --- |
| `PASS` | Nothing; bytes go straight through. |
| `ESCAPE` | Replaces two special bytes with two-byte escape codes, and can add a delimiter byte around each packet. |
| `UNESCAPE` | The reverse: a delimiter ends a packet, escape codes become the original bytes, a broken escape is tagged *err*. |
| `TAG` | Ends a packet when a fabric line fires (for example "the line has been quiet for 15 bit times"), or after a fixed number of bytes. Tags *err* if an error line was high during the packet. |
| `CHECK` | Adds an 8-bit checksum (add or xor) to each outgoing packet, or checks it on incoming packets and tags *err* if it is wrong. |
| `MATCH` | Keeps only packets whose first byte matches a value (an address filter). |

Configuration is at `0x60 + 4t`, where tile `t = 4 × channel + 2 × rx +
stage`:

| Reg | Field |
| --- | --- |
| 0 | `[2:0]` mode, `[3]` ESCAPE: add delimiter after, `[4]` ESCAPE: add delimiter before, `[5]` CHECK: xor (else add), `[6]` CHECK: verify (else generate) |
| 1 | ESCAPE/UNESCAPE: the two special bytes `{c1, c0}`; MATCH: `{mask, value}`; CHECK: start value; TAG: packet length |
| 2 | ESCAPE/UNESCAPE: their replacements `{m1, m0}`; TAG: `[5:0]` end line, `[11:6]` error line |
| 3 | ESCAPE/UNESCAPE: `{delimiter, escape byte}` |

Escape settings for common protocols:

| Protocol | Delimiter | Escape | Replacements |
| --- | --- | --- | --- |
| Async HDLC / PPP | `7E` | `7D` | `7E → 7D 5E`, `7D → 7D 5D` |
| SLIP | `C0` | `DB` | `C0 → DB DC`, `DB → DB DD` |

## Good to know

- **How bytes move:** a byte moves when the sender says "valid" and the
  receiver says "ready". Each tile handles at most one byte every 2
  cycles, much faster than any serial byte (the fastest takes 32 cycles).
- **Links to the bit fabric:**
  - TAG reads fabric lines;
  - an *eop* tag can end a shifter burst;
  - each tile's event (packet passed, matched, or failed) can wake the
    controller.

Next: [Controller](controller.md).
