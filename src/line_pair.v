`default_nettype none

// Two-pin line-state helper for differential-style buses (USB LS/FS, etc.).
// States: SE0=00, J, K, SE1=11. Not a protocol PHY — programs own framing.
module line_pair (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cfg_write,
    input  wire [2:0] pin_a,
    input  wire [2:0] pin_b,
    input  wire       jk_swap,
    input  wire       drive,
    input  wire [1:0] drive_state,
    input  wire       release_line,
    input  wire       sample,
    input  wire [7:0] pin_sampled,
    output reg  [7:0] claim,
    output wire       drive_enable,
    output wire [7:0] drive_out_value,
    output wire [7:0] drive_out_mask,
    output wire [7:0] drive_oe_value,
    output wire [7:0] drive_oe_mask,
    output reg  [1:0] sampled_state,
    output wire [1:0] sample_comb,
    output reg        state_changed
);
  localparam ST_SE0 = 2'd0;
  localparam ST_J   = 2'd1;
  localparam ST_K   = 2'd2;
  localparam ST_SE1 = 2'd3;

  reg [2:0] pin_a_r;
  reg [2:0] pin_b_r;
  reg       jk_swap_r;
  reg       active;
  reg [1:0] cur_state;

  wire [7:0] mask_a = 8'b1 << pin_a_r;
  wire [7:0] mask_b = 8'b1 << pin_b_r;
  wire [7:0] pair_mask = mask_a | mask_b;

  // LS default: J=(A=0,B=1), K=(A=1,B=0). jk_swap flips J/K levels.
  wire j_a = jk_swap_r ? 1'b1 : 1'b0;
  wire j_b = jk_swap_r ? 1'b0 : 1'b1;
  wire k_a = ~j_a;
  wire k_b = ~j_b;

  reg out_a;
  reg out_b;
  always @(*) begin
    case (cur_state)
      ST_SE0: begin out_a = 1'b0; out_b = 1'b0; end
      ST_J:   begin out_a = j_a;  out_b = j_b;  end
      ST_K:   begin out_a = k_a;  out_b = k_b;  end
      default: begin out_a = 1'b1; out_b = 1'b1; end
    endcase
  end

  assign drive_enable = active;
  assign drive_out_mask = active ? pair_mask : 8'b0;
  assign drive_oe_mask = active ? pair_mask : 8'b0;
  assign drive_out_value = active ?
      ((out_a ? mask_a : 8'b0) | (out_b ? mask_b : 8'b0)) : 8'b0;
  assign drive_oe_value = active ? pair_mask : 8'b0;

  function automatic [1:0] decode;
    input a;
    input b;
    input swap;
    reg ja, jb;
    begin
      ja = swap ? 1'b1 : 1'b0;
      jb = swap ? 1'b0 : 1'b1;
      if (a == 0 && b == 0)
        decode = ST_SE0;
      else if (a == 1 && b == 1)
        decode = ST_SE1;
      else if (a == ja && b == jb)
        decode = ST_J;
      else
        decode = ST_K;
    end
  endfunction

  // Mask isolate — avoids pin_sampled[idx] variable bit-select (formal X).
  wire a_level = |(pin_sampled & mask_a);
  wire b_level = |(pin_sampled & mask_b);
  assign sample_comb = decode(a_level, b_level, jk_swap_r);

  always @(posedge clk) begin
    if (!rst_n) begin
      pin_a_r <= 3'd0;
      pin_b_r <= 3'd1;
      jk_swap_r <= 1'b0;
      active <= 1'b0;
      cur_state <= ST_J;
      claim <= 8'b0;
      sampled_state <= ST_SE0;
      state_changed <= 1'b0;
    end else begin
      state_changed <= 1'b0;

      if (cfg_write) begin
        pin_a_r <= pin_a;
        pin_b_r <= pin_b;
        jk_swap_r <= jk_swap;
      end

      if (release_line) begin
        active <= 1'b0;
        claim <= 8'b0;
      end else if (drive) begin
        active <= 1'b1;
        cur_state <= drive_state;
        claim <= (8'b1 << pin_a_r) | (8'b1 << pin_b_r);
        if (cfg_write)
          claim <= (8'b1 << pin_a) | (8'b1 << pin_b);
      end

      if (sample) begin
        if (sample_comb != sampled_state)
          state_changed <= 1'b1;
        sampled_state <= sample_comb;
      end
    end
  end
endmodule

`default_nettype wire
