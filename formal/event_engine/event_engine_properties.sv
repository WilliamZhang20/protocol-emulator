`default_nettype none

module event_engine_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg timer_done_pulse;
  (* anyseq *) reg region_done_pulse;
  (* anyseq *) reg arm_edges;
  (* anyseq *) reg [7:0] rise_enable;
  (* anyseq *) reg [7:0] fall_enable;
  (* anyseq *) reg [7:0] gpio_rising;
  (* anyseq *) reg [7:0] gpio_falling;
  (* anyseq *) reg compare_match;
  (* anyseq *) reg compare_arm;
  (* anyseq *) reg wait_clear;
  (* anyseq *) reg [7:0] wait_mask;
  wire [7:0] pending;
  wire [7:0] event_detail;
  wire wait_matched;

  event_engine dut (
      .clk(clk), .rst_n(rst_n),
      .timer_done_pulse(timer_done_pulse),
      .region_done_pulse(region_done_pulse),
      .arm_edges(arm_edges), .rise_enable(rise_enable),
      .fall_enable(fall_enable), .gpio_rising(gpio_rising),
      .gpio_falling(gpio_falling), .compare_match(compare_match),
      .compare_arm(compare_arm), .wait_clear(wait_clear),
      .wait_mask(wait_mask), .pending(pending),
      .event_detail(event_detail), .wait_matched(wait_matched)
  );

  reg [2:0] timer_count = 3'd0;
  reg [2:0] region_count = 3'd0;
  reg rise_pending = 1'b0;
  reg fall_pending = 1'b0;
  reg compare_pending = 1'b0;
  reg [7:0] armed_rise = 8'b0;
  reg [7:0] armed_fall = 8'b0;
  reg armed_compare = 1'b0;
  reg prior_compare = 1'b0;
  reg [7:0] last_detail = 8'b0;
  wire [7:0] expected_pending = {
      1'b0, (region_count != 0), 1'b0, compare_pending,
      fall_pending, rise_pending, (timer_count != 0), 1'b0
  };
  wire [7:0] rise_hits = gpio_rising & armed_rise;
  wire [7:0] fall_hits = gpio_falling & armed_fall;
  wire compare_hit = armed_compare && compare_match && !prior_compare;

  function automatic [2:0] lowest_pin(input [7:0] pins);
    integer j;
    begin
      lowest_pin = 3'd0;
      for (j = 7; j >= 0; j = j - 1)
        if (pins[j]) lowest_pin = j[2:0];
    end
  endfunction

  reg [2:0] next_timer;
  reg [2:0] next_region;
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      timer_count <= 0;
      region_count <= 0;
      rise_pending <= 0;
      fall_pending <= 0;
      compare_pending <= 0;
      armed_rise <= 0;
      armed_fall <= 0;
      armed_compare <= 0;
      prior_compare <= 0;
      last_detail <= 0;
    end else begin
      assert(pending == expected_pending);
      assert(wait_matched == (|(expected_pending & wait_mask)));
      assert(event_detail == last_detail);
      prior_compare <= compare_match;

      next_timer = timer_count;
      if (timer_done_pulse && next_timer != 3'd7)
        next_timer = next_timer + 1'b1;
      if (wait_clear && wait_mask[1] && next_timer != 0)
        next_timer = next_timer - 1'b1;
      timer_count <= next_timer;

      next_region = region_count;
      if (region_done_pulse && next_region != 3'd7)
        next_region = next_region + 1'b1;
      if (wait_clear && wait_mask[6] && next_region != 0)
        next_region = next_region - 1'b1;
      region_count <= next_region;

      if (arm_edges) begin
        armed_rise <= rise_enable;
        armed_fall <= fall_enable;
        armed_compare <= compare_arm;
        rise_pending <= 0;
        fall_pending <= 0;
        compare_pending <= 0;
      end else begin
        if (|rise_hits) rise_pending <= 1;
        if (|fall_hits) fall_pending <= 1;
        if (armed_compare && compare_match) compare_pending <= 1;
      end
      if (wait_clear) begin
        if (wait_mask[2]) rise_pending <= 0;
        if (wait_mask[3]) fall_pending <= 0;
        if (wait_mask[4]) compare_pending <= 0;
      end

      if (!arm_edges && |rise_hits)
        last_detail <= {4'd2, 1'b0, lowest_pin(rise_hits)};
      else if (!arm_edges && |fall_hits)
        last_detail <= {4'd3, 1'b0, lowest_pin(fall_hits)};
      else if (!arm_edges && compare_hit)
        last_detail <= 8'h40;
      else if (region_done_pulse)
        last_detail <= 8'h60;
      else if (timer_done_pulse)
        last_detail <= 8'h10;

      cover(timer_done_pulse && wait_clear && wait_mask[1]);
      cover(region_count == 3'd7 && region_done_pulse);
      cover(|rise_hits && |fall_hits);
    end
  end
endmodule

`default_nettype wire
