# Contexts

## The problem

Many protocols have **phases**. For example:

- Ethernet sends short "link pulses", then a full frame, on the same two
  pins.
- A device might send with parity for one byte and without it for the
  next.

Without contexts, the controller has to rewrite tile settings between
phases. That takes time, and the controller has to be involved.

## The solution

Every timer, shifter, counter, glue cell and pin cell holds **two complete
configurations**, called *context 0* and *context 1*. One line from the
[signal space](signal-space.md) chooses which context is active. When that
line changes, every tile switches to its other configuration **two cycles
later**, all at once.

The line can be:

- **a pin:** something outside the chip picks the phase;
- **a glue cell's flip-flop:** the fabric decides its own phases, with no
  controller at all;
- **a controller flag:** the program picks the phase with one write
  instead of many.

## How to use it

1. Choose which contexts your writes go to (configuration `0x35`):

   | Value | Writes go to |
   | --- | --- |
   | `01` | context 0 (after reset) |
   | `10` | context 1 |
   | `11` | both |

2. Write settings that are the same in both phases to **both** (`11`).
3. Write phase-specific settings to each context separately.
4. Pick the line that selects the context (configuration `0x34`: `[5:0]`
   line number, `[6]` on).

In the Python helper:

```python
p.write_contexts(3)              # both contexts
p.timer(0, reload=23, phase=21, pulse=True, start=shifter_active(0))
p.write_contexts(1)              # context 0: 8N1
p.shifter(0, pre=1, post=1, post_val=1, idle=1, shift=timer_rise(0))
p.write_contexts(2)              # context 1: 8E1
p.shifter(0, pre=1, post=1, post_val=1, parity=1, idle=1, shift=timer_rise(0))
p.write_contexts(1)
p.context_select(pin_level(7))   # pin 7 picks the framing
```

## Good to know

- **Switching in the middle of a frame:** the new settings apply right
  away; a frame in progress ends at its next end event.
- **Not duplicated:** the CRC engine and the byte tiles keep one
  configuration, since they rarely change between phases.
- **Cost:** a second copy of about 800 configuration bits, plus a selector
  for each. The core grows by about 25%.

## Examples that are tested

- A pin switches a timer's period; the new period shows up within one
  period, with the controller doing nothing.
- A pin switches a UART between 8N1 and 8E1 from one byte to the next.
- A glue-cell flip-flop flips the context after every byte, so the framing
  alternates with no controller involvement.
- 10BASE-T uses context 0 for link pulses and context 1 for the frame.

Next: [Byte layer](byte-layer.md).
