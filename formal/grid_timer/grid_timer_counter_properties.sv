// grid_timer's counter function (mode[2], ACTOR_FABRIC.md A3) against
// fabric_counter, the counter cell it replaces, as the mesh sees them
// (mesh.v): the counter's step/data/clear on lines 1/33/2, written while
// the fabric is not running; its `reached` registered at the cell boundary
// (REG=1), at_least read directly. For every step rule, any limit (8 bits),
// any input sequence and any number of enable cycles, the merged cell's
// level equals at_least and its tick equals the registered reached. A host
// limit write while running is allowed when the count is 0 (the counter's
// contract: rewritten while idle).
module grid_timer_counter_properties (input wire clk);
  localparam W = 8;
  (* anyconst *) reg [7:0] limit;
  (* anyconst *) reg [1:0] rule;
  reg [3:0] t = 0;
  always @(posedge clk) if (t != 4'hf) t <= t + 1'b1;
  wire rst_n = t != 0;
  wire setup = t >= 1 && t <= 3;            // the three counter registers, then run
  (* anyseq *) reg arm_any, step, data, clear, live;
  (* anyseq *) reg [7:0] live_value;
  wire arm = !setup && rst_n && arm_any;
  wire live_we = arm && live && dut_count == 0 && !step && !clear;

  // fabric_counter, configured as mesh.v's compiler does
  wire [12:0] cfg = t == 1 ? {5'b0, limit} : t == 2 ? {rule, 5'd1, 6'd1} : 13'd2;
  wire [63:0] lines = {30'b0, data, 1'b0, 29'b0, clear, step, 1'b0};
  wire ge, hit; wire [7:0] dut_count;
  fabric_counter ref_c(.clk(clk), .rst_n(rst_n), .enable(arm), .cfg_we(setup || live_we),
      .cfg_addr(setup ? t[1:0] - 2'd1 : 2'd0), .cfg_data(setup ? cfg : {5'b0, live_value}),
      .cfg_bank(2'b11), .ctx_next(1'b0), .lines(lines), .ge(ge), .hit(hit), .count(dut_count), .f_state(c_state));
  wire [26:0] c_state;
  wire [7:0] c_match = c_state[26:19]; wire [12:0] c_step = c_state[18:6]; wire [4:0] c_clear = c_state[5:1];
  wire c_last = c_state[0];
  reg hit_q;
  always @(posedge clk) hit_q <= rst_n && hit;

  // the merged cell, counter function
  wire tick, running, configured, level, rise, fall; wire [W-1:0] cap;
  grid_timer #(.W(W)) dut(.clk(clk), .rst_n(rst_n), .arm(arm), .cfg_we(setup), .cfg_first(limit),
      .cfg_period(8'd1), .live_we(live_we), .live_first(live_value), .live_period(8'd1),
      .mode({13'd0, 1'b1, rule}), .phase(8'd0), .start(step), .stop(data), .aux(clear),
      .tick(tick), .running(running), .configured(configured), .level(level), .rise(rise), .fall(fall),
      .captured(cap), .f_state(t_state), .f_last(t_last));
  wire [6*W+1:0] t_state; wire t_last;
  wire [W-1:0] t_first = t_state[6*W+1-:W], t_remaining = t_state[4*W+1-:W];

  always @(posedge clk) if (t >= 4) begin
    assert (level == ge);
    assert (tick == hit_q);
    assert (!rise && !fall);
    assert (configured);
    // The state correspondence (for induction): the same limit and step
    // rule, remaining = limit - count (0 once reached), the same last data.
    assert (t_first == c_match);
    assert (t_remaining == (c_match > dut_count ? c_match - dut_count : 8'd0));
    assert (t_last == c_last);
    assert (ge == (dut_count >= c_match));
    assert (c_step == {rule, 5'd1, 6'd1});
    assert (c_clear == 5'd2);
    assert (hit_q == tick);
  end
  // The interesting behaviours are reachable.
  always @(posedge clk) if (t >= 4) begin
    cover (tick && rule == 3 && limit == 3);
    cover (tick && rule == 1 && limit == 2);
    cover (level && !ge == 0 && live_we);
  end
endmodule
