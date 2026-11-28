`default_nettype none
// Grid timer tile. Start loads `first`; while running, `remaining` counts
// down and every expiry ticks (one clock), toggles `level` (with rise/fall
// pulses) and reloads `period`. Stop clears it. Configuration (first,
// period) is written while disarmed; while armed a live write goes to a
// shadow that takes effect at the next reload, so a running bit period is
// never cut short. Zero first or period is invalid.
//
// The third input `aux` does what `mode[1:0]` selects:
//   0 hold     counting pauses while aux is high (the original timer)
//   1 count    remaining decrements on aux pulses, not clocks: a tick after
//              N input events
//   2 capture  an aux pulse latches the clocks since the previous capture
//              (or arming) into `captured` and restarts that count; the
//              count saturates and runs whether or not the timer does
//   3 resync   an aux pulse while running moves remaining to `phase`,
//              limited to +/- mode[15:8] clocks (0: no limit), so the next
//              tick lands `phase` clocks after the edge (a receiver tracks
//              its sender's bit edges; CAN-style limited resynchronization).
//              The phase error is cyclic: an edge that arrives with more
//              than phase + period/2 clocks remaining came just after the
//              tick that sampled its bit (a slow sender), so the target is
//              phase + period, the next bit's sample, not a second sample
//              of the same bit. The result saturates at the counter's top.
//              A tick due on that clock still happens.
// mode[2] = 1 makes it a counter (ACTOR_FABRIC.md A3: one timer/counter
// PE) instead: `first` is the limit, start is the step pulse, stop the data
// level, aux the clear pulse (priority over step). It counts steps down from
// the limit (remaining = limit - count, saturating at 0), so `level` is
// count >= limit (a register, changing with the count; 1 for limit 0) and
// `tick` pulses, a clock after the step, when the count first reaches the
// limit. mode[1:0] is then the step rule:
//   0 count    every step counts
//   1 ones     a step with data 0 restarts the count at 0
//   2 zeros    a step with data 1 restarts the count at 0
//   3 equal    a step whose data differs from the previous step's restarts
//              the count at 1 (runs of equal bits)
// A live write sets the limit and restarts the count (zero allowed). The
// limit may be zero; `period` and `phase` are unused; rise and fall stay 0.
// mode[7:3] are reserved and must be zero.
// LIVE = 0: no live writes in timer mode (the shadow registers are not
// built); the counter's live limit write still works.
module grid_timer #(parameter W=16, parameter LIVE=1)(
    input wire clk, rst_n, arm, cfg_we,
    input wire [W-1:0] cfg_first, cfg_period,
    input wire live_we, input wire [W-1:0] live_first, live_period,
    input wire [15:0] mode, input wire [W-1:0] phase,
    input wire start, stop, aux,
    output reg tick, running, output wire configured,
    output reg level, rise, fall,
    output reg [W-1:0] captured
`ifdef FORMAL
    // Internal state for the formal reference-model correspondence.
    , output wire [6*W+1:0] f_state
    , output wire f_last
`endif
    );
  reg [W-1:0] first, period, remaining, next_first, next_period, elapsed;
  reg valid, pending;
  reg last;                       // counter: the previous step's data
  wire counter = mode[2];
  wire [1:0] fn = counter ? 2'd0 : mode[1:0];
  wire [7:0] limit = mode[15:8];
  assign configured = (valid || counter) && mode[7:3] == 0;
  wire hold = fn == 2'd0 && aux;
  // Counter step: the count one more (remaining one less, saturating), or
  // restarted at 0 (remaining = limit) or at 1.
  wire [W-1:0] dec = remaining == 0 ? {W{1'b0}} : remaining - 1'b1;
  wire [W-1:0] from_one = first == 0 ? {W{1'b0}} : first - 1'b1;
  reg [W-1:0] cnext;
  always @(*)
    case (mode[1:0])
      2'd0: cnext = dec;
      2'd1: cnext = stop ? dec : first;
      2'd2: cnext = stop ? first : dec;
      default: cnext = stop == last ? dec : from_one;
    endcase
  wire step = fn == 2'd1 ? aux : !hold;
  // Resynchronization target, clamped to +/- limit around remaining.
  wire [W:0] lo = (limit == 0 || {1'b0, remaining} <= {{(W-7){1'b0}}, limit}) ? {(W+1){1'b0}} : {1'b0, remaining} - {{(W-7){1'b0}}, limit};
  wire [W:0] hi = (limit == 0) ? {1'b1, {W{1'b0}}} : {1'b0, remaining} + {{(W-7){1'b0}}, limit};
  wire late_edge = {1'b0, remaining} > {1'b0, phase} + {2'b0, period[W-1:1]};
  wire [W:0] want = late_edge ? {1'b0, phase} + {1'b0, period} : {1'b0, phase};
  wire [W:0] clamped = want < lo ? lo : want > hi ? hi : want;
  wire [W-1:0] saturated = clamped[W] ? {W{1'b1}} : clamped[W-1:0];
  wire [W-1:0] resync_to = saturated == 0 ? {{(W-1){1'b0}}, 1'b1} : saturated;
`ifdef FORMAL
  assign f_state = {first, period, remaining, next_first, next_period, elapsed, valid, pending};
  assign f_last = last;
`endif
  always @(posedge clk) begin
    if (!rst_n) begin
      first <= 0; period <= 0; remaining <= 0; valid <= 0; tick <= 0; running <= 0;
      level <= 0; rise <= 0; fall <= 0; captured <= 0; elapsed <= 0;
      next_first <= 0; next_period <= 0; pending <= 0; last <= 0;
    end else if (counter) begin
      // The counter (mode[2]).
      tick <= 0; rise <= 0; fall <= 0; running <= 0; pending <= 0; elapsed <= 0; captured <= 0;
      if (!arm) begin
        last <= 0;
        if (cfg_we) begin
          first <= cfg_first; period <= cfg_period; valid <= 1;
          remaining <= cfg_first; level <= cfg_first == 0;
        end else begin
          remaining <= first; level <= first == 0;
        end
      end else if (live_we) begin
        first <= live_first; remaining <= live_first; level <= live_first == 0;
      end else if (aux) begin
        remaining <= first; level <= first == 0;
      end else if (start) begin
        remaining <= cnext; level <= cnext == 0; last <= stop;
        tick <= remaining != 0 && cnext == 0;
      end
    end else begin
      tick <= 0; rise <= 0; fall <= 0;
      if (!arm) begin
        running <= 0; remaining <= 0; level <= 0; pending <= 0; elapsed <= 0; captured <= 0;
        if (cfg_we) begin
          first <= cfg_first; period <= cfg_period;
          valid <= (cfg_first != 0 && cfg_period != 0);
        end
      end else begin
        if (LIVE && live_we && live_first != 0 && live_period != 0) begin
          next_first <= live_first; next_period <= live_period; pending <= 1;
        end
        if (stop) begin
          running <= 0; remaining <= 0; level <= 0;
        end else if (start && valid && !running) begin
          running <= 1;
          remaining <= (pending && !live_we) ? next_first : first;
          if (pending && !live_we) begin first <= next_first; period <= next_period; pending <= 0; end
        end else if (running) begin
          if (fn == 2'd3 && aux) begin
            remaining <= resync_to;
            // A tick due on this clock still happens: the edge moves the
            // next tick, it never removes a due one (a half-bit grid whose
            // edges land as a tick is due: Manchester).
            if (remaining == 1) begin
              tick <= 1; level <= !level;
              if (level) fall <= 1; else rise <= 1;
              if (pending && !live_we) begin first <= next_first; period <= next_period; pending <= 0; end
            end
          end else if (step) begin
            if (remaining == 1) begin
              tick <= 1; level <= !level;
              if (level) fall <= 1; else rise <= 1;
              if (pending && !live_we) begin
                remaining <= next_period; first <= next_first; period <= next_period; pending <= 0;
              end else remaining <= period;
            end else remaining <= remaining - 1'b1;
          end
        end
        // Capture counts clocks whether or not the timer runs.
        if (fn == 2'd2) begin
          if (aux) begin captured <= elapsed; elapsed <= 1; end
          else if (elapsed != {W{1'b1}}) elapsed <= elapsed + 1'b1;
        end
      end
    end
  end
endmodule
`default_nettype wire
