`default_nettype none

// Sticky event scoreboard with counted tokens for XFER/TIMER completions so
// back-to-back resource finishes are not lost when WAIT_EVENT has not run yet.
// Edge/compare sources remain level-sticky. WAIT_EVENT ORs a mask against
// pending and consumes one token (or clears sticky) per matched bit.
module event_engine (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       xfer_done_pulse,
    input  wire       timer_done_pulse,
    input  wire       line_changed_pulse,
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
    output wire       wait_matched
);
  localparam BIT_XFER    = 0;
  localparam BIT_TIMER   = 1;
  localparam BIT_RISE    = 2;
  localparam BIT_FALL    = 3;
  localparam BIT_COMPARE = 4;
  localparam BIT_LINE    = 5;

  reg [2:0] xfer_tokens;
  reg [2:0] timer_tokens;
  reg       rise_sticky;
  reg       fall_sticky;
  reg       compare_sticky;
  reg       line_sticky;
  reg [7:0] rise_mask;
  reg [7:0] fall_mask;
  reg       compare_enabled;

  wire rise_hit = |(gpio_rising & rise_mask);
  wire fall_hit = |(gpio_falling & fall_mask);

  wire [7:0] pending_reg = {
      2'b0,
      line_sticky,
      compare_sticky,
      fall_sticky,
      rise_sticky,
      (timer_tokens != 3'b0),
      (xfer_tokens != 3'b0)
  };

  assign pending = pending_reg;
  assign wait_matched = |(pending_reg & wait_mask);

  always @(posedge clk) begin
    if (!rst_n) begin
      xfer_tokens <= 3'b0;
      timer_tokens <= 3'b0;
      rise_sticky <= 1'b0;
      fall_sticky <= 1'b0;
      compare_sticky <= 1'b0;
      line_sticky <= 1'b0;
      rise_mask <= 8'b0;
      fall_mask <= 8'b0;
      compare_enabled <= 1'b0;
    end else begin
      if (arm_edges) begin
        rise_mask <= rise_enable;
        fall_mask <= fall_enable;
        compare_enabled <= compare_arm;
        rise_sticky <= 1'b0;
        fall_sticky <= 1'b0;
        compare_sticky <= 1'b0;
        line_sticky <= 1'b0;
      end else begin
        if (rise_hit)
          rise_sticky <= 1'b1;
        if (fall_hit)
          fall_sticky <= 1'b1;
        if (compare_enabled && compare_match)
          compare_sticky <= 1'b1;
        if (line_changed_pulse)
          line_sticky <= 1'b1;
      end

      // Produce/consume with a single next-state so same-cycle done+wait nets out.
      begin : xfer_token_update
        reg [2:0] next_xfer;
        next_xfer = xfer_tokens;
        if (xfer_done_pulse && next_xfer != 3'b111)
          next_xfer = next_xfer + 1'b1;
        if (wait_clear && wait_mask[BIT_XFER] && next_xfer != 3'b0)
          next_xfer = next_xfer - 1'b1;
        xfer_tokens <= next_xfer;
      end
      begin : timer_token_update
        reg [2:0] next_timer;
        next_timer = timer_tokens;
        if (timer_done_pulse && next_timer != 3'b111)
          next_timer = next_timer + 1'b1;
        if (wait_clear && wait_mask[BIT_TIMER] && next_timer != 3'b0)
          next_timer = next_timer - 1'b1;
        timer_tokens <= next_timer;
      end

      if (wait_clear) begin
        if (wait_mask[BIT_RISE])
          rise_sticky <= 1'b0;
        if (wait_mask[BIT_FALL])
          fall_sticky <= 1'b0;
        if (wait_mask[BIT_COMPARE])
          compare_sticky <= 1'b0;
        if (wait_mask[BIT_LINE])
          line_sticky <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
