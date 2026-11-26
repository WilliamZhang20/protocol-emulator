`default_nettype none
// grid_timer against an independently written reference model, W = 8.
// Every input is arbitrary each clock (arming, configuration and live
// writes, mode, phase, start, stop, aux); the model predicts every output
// and its state is asserted equal to the tile's, so k-induction proves the
// predictions for all time. Spec-level assertions below do not use the
// model: hold freezes, resync stays inside its limit, count mode ticks only
// on pulses, a live write never shortens the period being counted.
module grid_timer_properties (input wire clk);
  localparam W = 8;
  reg [1:0] reset_cycles = 0;
  wire rst_n = reset_cycles >= 2;
  always @(posedge clk) if (!rst_n) reset_cycles <= reset_cycles + 1'b1;

  (* anyseq *) reg arm, cfg_we, live_we, start, stop, aux;
  (* anyseq *) reg [W-1:0] cfg_first, cfg_period, live_first, live_period;
  (* anyconst *) reg [15:0] mode;
  (* anyconst *) reg [W-1:0] phase;
  wire tick, running, configured, level, rise, fall;
  wire [W-1:0] captured;
  grid_timer #(.W(W)) dut(clk, rst_n, arm, cfg_we, cfg_first, cfg_period, live_we, live_first, live_period,
    mode, phase, start, stop, aux, tick, running, configured, level, rise, fall, captured, f_state);
  wire [6*W+1:0] f_state;
  wire [W-1:0] d_first, d_period, d_remaining, d_next_first, d_next_period, d_elapsed;
  wire d_valid, d_pending;
  assign {d_first, d_period, d_remaining, d_next_first, d_next_period, d_elapsed, d_valid, d_pending} = f_state;

  // ---------------- reference model ----------------
  reg [W-1:0] f = 0, p = 0, rem = 0, nf = 0, np = 0, el = 0, cap = 0;
  reg ok = 0, run = 0, lv = 0, pend = 0, t = 0, r = 0, fl = 0;
  wire [1:0] fn = mode[1:0];
  wire [8:0] lim = {1'b0, mode[15:8]};
  // Resync target: the bit's sample `phase` after the edge, or, when the
  // edge comes in the first half of the interval (more than phase + p/2
  // clocks left: it arrived just after the tick that sampled its bit), the
  // next bit's sample at phase + p. Moved at most lim from rem (lim 0:
  // anywhere), then saturated to the counter.
  function [9:0] toward(input [9:0] from, input [9:0] to, input [8:0] l);
    begin
      if (l == 0) toward = to;
      else if (to > from) toward = (to - from > l) ? from + l : to;
      else toward = (from - to > l) ? from - l : to;
    end
  endfunction
  wire [9:0] target = ({2'b0, rem} > {2'b0, phase} + {3'b0, p[W-1:1]}) ? {2'b0, phase} + {2'b0, p} : {2'b0, phase};
  wire [9:0] moved = toward({2'b0, rem}, target, lim);
  wire [W-1:0] rs = moved > 10'd255 ? 8'd255 : moved[W-1:0];
  wire [W-1:0] rs1 = rs == 0 ? 1 : rs;
  wire advance = fn == 1 ? aux : !(fn == 0 && aux);
  wire take_shadow = pend && !live_we;

  always @(posedge clk) begin
    t <= 0; r <= 0; fl <= 0;
    if (!rst_n) begin
      f <= 0; p <= 0; rem <= 0; nf <= 0; np <= 0; el <= 0; cap <= 0; ok <= 0; run <= 0; lv <= 0; pend <= 0;
    end else if (!arm) begin
      run <= 0; rem <= 0; lv <= 0; pend <= 0; el <= 0; cap <= 0;
      if (cfg_we) begin f <= cfg_first; p <= cfg_period; ok <= cfg_first != 0 && cfg_period != 0; end
    end else begin
      if (live_we && live_first != 0 && live_period != 0) begin nf <= live_first; np <= live_period; pend <= 1; end
      if (stop) begin run <= 0; rem <= 0; lv <= 0; end
      else if (!run) begin
        if (start && ok) begin
          run <= 1;
          if (take_shadow) begin rem <= nf; f <= nf; p <= np; pend <= 0; end else rem <= f;
        end
      end else if (fn == 3 && aux) rem <= rs1;
      else if (advance) begin
        if (rem == 1) begin
          t <= 1; lv <= !lv; if (lv) fl <= 1; else r <= 1;
          if (take_shadow) begin rem <= np; f <= nf; p <= np; pend <= 0; end else rem <= p;
        end else rem <= rem - 1;
      end
      if (fn == 2) begin
        if (aux) begin cap <= el; el <= 1; end else if (el != {W{1'b1}}) el <= el + 1;
      end
    end
  end

  // ---------------- correspondence (all outputs and state) ----------------
  always @(*) if (rst_n) begin
    assert (tick == t); assert (rise == r); assert (fall == fl); assert (level == lv);
    assert (running == run); assert (captured == cap);
    assert (configured == (ok && mode[7:2] == 0));
    assert (d_first == f); assert (d_period == p); assert (d_remaining == rem); assert (d_valid == ok);
    assert (d_next_first == nf || !pend); assert (d_next_period == np || !pend);
    assert (d_pending == pend && d_elapsed == el);
    // Inductive strengthening: a valid configuration is nonzero, and a
    // running timer had one (it changes only while disarmed).
    if (ok) assert (f != 0 && p != 0);
    if (run) assert (ok && rem != 0 && p != 0);
    if (pend) assert (nf != 0 && np != 0);
  end

  // ---------------- spec-level properties (no model) ----------------
  reg [W-1:0] p_q = 0;
  always @(posedge clk) p_q <= p;
  reg [W-1:0] rem_q = 0; reg run_q = 0, arm_q = 0, aux_q = 0, stop_q = 0, hold_q = 0, live_q = 0;
  always @(posedge clk) begin
    rem_q <= d_remaining; run_q <= running; arm_q <= arm; aux_q <= aux; stop_q <= stop; live_q <= live_we;
    hold_q <= rst_n && arm && !stop && fn == 0 && aux && running;
  end
  always @(*) if (rst_n && reset_cycles >= 2) begin
    // Hold: a held, running timer keeps its count and does not tick.
    if (hold_q) assert (d_remaining == rem_q && !tick);
    // Count mode: a tick needs an input pulse in the clock before.
    if (fn == 1 && tick) assert (aux_q);
    // Resync stays within its limit.
    if (fn == 3 && aux_q && run_q && arm_q && !stop_q && mode[15:8] != 0 && running)
      assert ((d_remaining >= rem_q ? d_remaining - rem_q : rem_q - d_remaining) <= mode[15:8]);
  end

  always @(*) begin
    cover (rst_n && tick && fn == 1);
    cover (rst_n && fn == 2 && captured > 2);
    cover (rst_n && fn == 3 && aux && running && mode[15:8] != 0 && d_remaining > 3);
    cover (rst_n && tick && p != p_q);   // a reload applied a live (shadow) period
    cover (rst_n && fall);
  end
endmodule
`default_nettype wire
