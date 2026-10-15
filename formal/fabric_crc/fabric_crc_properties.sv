`default_nettype none

// CRC tile (32-bit configuration) against the mirror-image formulation used
// by software: a right-shifting register with the bit-reversed polynomial.
// The two agree on every absorb, emit, init, output bit and residue match.
module fabric_crc_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [2:0]  cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [63:0] lines_any;
  wire [63:0] lines = {lines_any[63:2], 1'b1, 1'b0};
  wire out, ok;
  wire [31:0] value;

  fabric_crc dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .lines(lines), .out(out), .ok(ok), .value(value)
  );

  function automatic [31:0] reverse(input [31:0] v);
    integer i;
    for (i = 0; i < 32; i = i + 1) reverse[i] = v[31 - i];
  endfunction

  reg [31:0] poly_s = 32'd0, check_s = 32'd0;
  reg [10:0] absorb_s = 11'd0, emit_s = 11'd0;
  reg        ones_s = 1'b0;
  reg [31:0] r = 32'd0;      // reflected register
  reg        configured = 1'b0;

  // Width fixed at 32 bits: the shape register is only ever written as such.
  always @(*) if (rst_n && cfg_we && cfg_addr == 3'd6) assume(cfg_data[4:0] == 5'd31);
  always @(*) if (rst_n && cfg_we) assume(!enable);

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      poly_s <= 32'd0; check_s <= 32'd0; absorb_s <= 11'd0; emit_s <= 11'd0;
      ones_s <= 1'b0; r <= 32'd0; configured <= 1'b0;
    end else begin
      if (cfg_we) begin
        case (cfg_addr)
          3'd0: poly_s[15:0] <= cfg_data;
          3'd1: poly_s[31:16] <= cfg_data;
          3'd2: check_s[15:0] <= cfg_data;
          3'd3: check_s[31:16] <= cfg_data;
          3'd4: absorb_s <= cfg_data[10:0];
          3'd5: emit_s <= cfg_data[10:0];
          3'd6: begin ones_s <= cfg_data[5]; configured <= 1'b1; end
          default: begin end
        endcase
      end
      if (!enable || lines[{1'b0, emit_s[10:6]}])
        r <= ones_s ? 32'hffffffff : 32'd0;
      else if (lines[absorb_s[5:0]])
        r <= (r >> 1) ^ ((r[0] ^ lines[{1'b1, absorb_s[10:6]}]) ? reverse(poly_s) : 32'd0);
      else if (lines[emit_s[5:0]])
        r <= r >> 1;
    end
  end

  reg past_valid = 1'b0;
  always @(posedge clk) past_valid <= rst_n && configured;

  always @(*) begin
    if (rst_n && past_valid) begin
      assert(value == reverse(r));
      assert(out == !r[0]);
      assert(ok == (r == reverse(check_s)));
      cover(ok && enable && poly_s == 32'h04c11db7);
    end
  end
endmodule

`default_nettype wire
