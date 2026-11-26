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
// mode[7:2] are reserved and must be zero.
module grid_timer #(parameter W=16)(
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
`endif
    );
  reg [W-1:0] first, period, remaining, next_first, next_period, elapsed;
  reg valid, pending;
  wire [1:0] fn = mode[1:0];
  wire [7:0] limit = mode[15:8];
  assign configured = valid && mode[7:2] == 0;
  wire hold = fn == 2'd0 && aux;
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
`endif
  always @(posedge clk) begin
    if (!rst_n) begin
      first <= 0; period <= 0; remaining <= 0; valid <= 0; tick <= 0; running <= 0;
      level <= 0; rise <= 0; fall <= 0; captured <= 0; elapsed <= 0;
      next_first <= 0; next_period <= 0; pending <= 0;
    end else begin
      tick <= 0; rise <= 0; fall <= 0;
      if (!arm) begin
        running <= 0; remaining <= 0; level <= 0; pending <= 0; elapsed <= 0; captured <= 0;
        if (cfg_we) begin
          first <= cfg_first; period <= cfg_period;
          valid <= (cfg_first != 0 && cfg_period != 0);
        end
      end else begin
        if (live_we && live_first != 0 && live_period != 0) begin
          next_first <= live_first; next_period <= live_period; pending <= 1;
        end
        if (stop) begin
          running <= 0; remaining <= 0; level <= 0;
        end else if (start && valid && !running) begin
          running <= 1;
          remaining <= (pending && !live_we) ? next_first : first;
          if (pending && !live_we) begin first <= next_first; period <= next_period; pending <= 0; end
        end else if (running) begin
          if (fn == 2'd3 && aux) remaining <= resync_to;
          else if (step) begin
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
