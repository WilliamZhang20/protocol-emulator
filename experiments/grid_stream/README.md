# Credit-based grid streams

The grid top uses one generic sequential reader and one sequential writer,
each with a two-byte FIFO. Each accepted read reserves a FIFO slot until its
ordered response arrives; `queued + outstanding <= depth`. A read may be
issued every cycle when there is credit. The writer accepts data only when
there is a reserved slot and retains a stalled memory request unchanged. Host,
reader and writer have independent requests and a round-robin arbiter in each
single-port SRAM bank. Configuration word 88 independently selects a bank for
host, reader and writer in bits 0, 1 and 2; reserved bits must be zero. The
legacy two-bit bank command assigns reader and writer together as a default.
Descriptors use a starting bank plus a 10-bit offset and can continue from
bank 0 into bank 1, up to 2 KiB total without wrap. The reader drains older
requests at a bank boundary before issuing to the next bank so different
latencies cannot reorder bytes. Multiple readers and a shared return network
remain an experiment, not part of the chip top.

A common frame scheduler reads one or two bytes per shifter lane, starts the
configured shifters and sends received bytes to the writer. It can repeat
frames over a longer TX stream. An independent flag starts the RX writer on
arm for a receiver that runs without TX. There is no SPI-versus-UART memory
mode, but the frame scheduler is still hand-written; the compiler has not
lowered general source transactions or dynamic frame widths into it. In
frame-coupled operation the requested RX length must match the produced data;
mismatches and partial TX frames signal an error. An autonomous receiver can
overrun a full writer, so it reports sticky overflow instead of pretending a
non-stallable source can be backpressured.

`make grid-stream-test` checks:

* Both streams moving 32 bytes from/to one SRAM bank at a 16-cycle byte
  period while a host continually contends. After prefill, every byte must be
  ready on its scheduled cycle. This workload observed one denied cycle and
  two cycles from request to FIFO; a separate all-requesters-active test reaches
  the round-robin maximum of two denied cycles.
* Two read credits outstanding with a synthetic four-cycle ordered response
  path and a periodically stalled consumer, including disarm, stale-response
  drain and restart. A deliberate missing-reservation mutation must fail.
* Two independent credited readers and one writer share a modeled four-cycle
  tagged return path with a contending host, without deadline misses in the
  tested 16-cycle-period schedule. This is not the current chip's return path.
* A 1,518-byte reader and a 200-byte writer cross the two IHP SRAM models;
  another test uses different bank response latencies to check ordering.
* A separate two-alternative prefetch probe: both one-byte alternatives are
  fetched into reserved slots, then either late choice is available after one
  control clock. This probe is not connected to the grid top or I2C control.

Assertions check queue/credit bounds and stable stalled requests. These finite
simulations are not a proof for all traffic. For a periodic one-byte consumer,
the compiler lab calculates `ceil(worst_refill / byte_period) + 1`, with an
additional startup burst requirement and an independent sustained-service
check. Bank-boundary drain time must be included in the refill bound. A
four-cycle refill and a 16-cycle byte interval give depth two only
under the stated fairness, initial prefetch, ordered-return and bounded-load
assumptions. A full 8×4 fabric with multiple readers needs per-stream credits,
response tags and a proved fair return network. Credits alone do not prove
freedom from every cyclic resource dependency or guarantee physical timing.
