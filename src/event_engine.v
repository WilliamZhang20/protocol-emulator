`default_nettype none

// Sticky event scoreboard with counted TIMER/REGION completion tokens
// so back-to-back resource finishes are not lost when WAIT_EVENT has not run
// yet. Edge/compare sources remain level-sticky. WAIT_EVENT ORs a mask against
// pending and consumes one token (or clears sticky) per matched bit.
module event_engine (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       timer_done_pulse,
    input  wire [1:0] region_done_count,
    input  wire       region_done_lane,
    input  wire       arm_edges,
    input  wire [7:0] rise_enable,
    input  wire [7:0] fall_enable,
    input  wire [7:0] gpio_rising,
    input  wire [7:0] gpio_falling,
    input  wire       compare_match,
    input  wire       compare_arm,
    input  wire       wait_clear,
    input  wire [7:0] wait_mask,
    output wire [7:0] pending,
    output reg  [7:0] event_detail,
    output wire       wait_matched
);
  localparam BIT_TIMER   = 1;
  localparam BIT_RISE    = 2;
  localparam BIT_FALL    = 3;
  localparam BIT_COMPARE = 4;
  localparam BIT_REGION  = 6;

  reg [2:0] timer_tokens;
  reg [2:0] region_tokens;
  reg       rise_sticky;
  reg       fall_sticky;
  reg       compare_sticky;
  reg [7:0] rise_mask;
  reg [7:0] fall_mask;
  reg       compare_enabled;
  reg       compare_previous;
  wire compare_hit = compare_enabled && compare_match && !compare_previous;

  wire [7:0] rise_pins = gpio_rising & rise_mask;
  wire [7:0] fall_pins = gpio_falling & fall_mask;
  wire rise_hit = |rise_pins;
  wire fall_hit = |fall_pins;
  function automatic [2:0] first_pin(input [7:0] pins);
    integer i;
    begin
      first_pin = 3'd0;
      for (i = 7; i >= 0; i = i - 1)
        if (pins[i]) first_pin = i[2:0];
    end
  endfunction

  wire [7:0] pending_reg = {
      1'b0,
      (region_tokens != 3'b0),
      1'b0,
      compare_sticky,
      fall_sticky,
      rise_sticky,
      (timer_tokens != 3'b0),
      1'b0
  };

  assign pending = pending_reg;
  assign wait_matched = |(pending_reg & wait_mask);

  always @(posedge clk) begin
    if (!rst_n) begin
      timer_tokens <= 3'b0;
      region_tokens <= 3'b0;
      rise_sticky <= 1'b0;
      fall_sticky <= 1'b0;
      compare_sticky <= 1'b0;
      rise_mask <= 8'b0;
      fall_mask <= 8'b0;
      compare_enabled <= 1'b0;
      compare_previous <= 1'b0;
      event_detail <= 8'b0;
    end else begin
      compare_previous <= compare_match;
      if (arm_edges) begin
        rise_mask <= rise_enable;
        fall_mask <= fall_enable;
        compare_enabled <= compare_arm;
        rise_sticky <= 1'b0;
        fall_sticky <= 1'b0;
        compare_sticky <= 1'b0;
      end else begin
        if (rise_hit)
          rise_sticky <= 1'b1;
        if (fall_hit)
          fall_sticky <= 1'b1;
        if (compare_enabled && compare_match)
          compare_sticky <= 1'b1;
      end

      // Most recent event detail: source[7:4], logical pin[2:0].
      // Pin edges take priority when sources coincide on one clock.
      if (!arm_edges && rise_hit)
        event_detail <= {4'd2, 1'b0, first_pin(rise_pins)};
      else if (!arm_edges && fall_hit)
        event_detail <= {4'd3, 1'b0, first_pin(fall_pins)};
      else if (!arm_edges && compare_hit)
        event_detail <= {4'd4, 4'b0};
      else if (region_done_count != 0)
        event_detail <= {4'd6, 3'b0, region_done_lane};
      else if (timer_done_pulse)
        event_detail <= {4'd1, 4'b0};

      // Produce/consume with a single next-state so same-cycle done+wait nets out.
      begin : timer_token_update
        reg [2:0] next_timer;
        next_timer = timer_tokens;
        if (timer_done_pulse && next_timer != 3'b111)
          next_timer = next_timer + 1'b1;
        if (wait_clear && wait_mask[BIT_TIMER] && next_timer != 3'b0)
          next_timer = next_timer - 1'b1;
        timer_tokens <= next_timer;
      end
      begin : region_token_update
        reg [2:0] next_region;
        next_region = region_tokens;
        if (region_done_count != 0) begin
          if ({1'b0, next_region} + {2'b0, region_done_count} >= 4'd7)
            next_region = 3'b111;
          else
            next_region = next_region + region_done_count;
        end
        if (wait_clear && wait_mask[BIT_REGION] && next_region != 3'b0)
          next_region = next_region - 1'b1;
        region_tokens <= next_region;
      end

      if (wait_clear) begin
        if (wait_mask[BIT_RISE])
          rise_sticky <= 1'b0;
        if (wait_mask[BIT_FALL])
          fall_sticky <= 1'b0;
        if (wait_mask[BIT_COMPARE])
          compare_sticky <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
