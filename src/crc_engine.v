`default_nettype none

// Programmable CRC datapath (protocol-neutral). Width 1..16 via CRC_SETUP,
// plus one-pulse IEEE-802.3 CRC-32 setup (width 32, poly 0x04C11DB7,
// init/xor ones, refin/refout). Reflect-in on feed, reflect-out/xor applied
// only when `finalize` pulses. Setup/feed/finalize/push semantics for
// widths 1..16 are unchanged.
// Uses shifts/masks (no variable bit-selects) so formal AIGER stays X-free.
module crc_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        setup,
    input  wire        setup32,
    input  wire [7:0]  cfg,
    input  wire [15:0] poly,
    input  wire        feed,
    input  wire [7:0]  feed_byte,
    input  wire        finalize,
    output reg  [31:0] crc,
    output wire        busy
);
  // cfg: {init_ones, xor_ones, refout, refin, width_m1[3:0]}
  wire [3:0] width_m1 = cfg[3:0];
  wire       init_ones = cfg[7];
  wire [4:0] width = {1'b0, width_m1} + 5'd1;
  wire [15:0] width_mask = (16'hFFFF >> (5'd16 - width));

  localparam [31:0] CRC32_POLY = 32'h04C11DB7;

  assign busy = 1'b0;

  function automatic [7:0] rev8(input [7:0] v);
    integer i;
    begin
      for (i = 0; i < 8; i = i + 1)
        rev8[i] = v[7 - i];
    end
  endfunction

  function automatic [31:0] rev_w(input [31:0] v, input [5:0] w);
    integer i;
    integer wi;
    begin
      rev_w = 32'b0;
      wi = {26'd0, w};
      for (i = 0; i < 32; i = i + 1)
        if (i < wi)
          rev_w[i] = |( (v >> (wi - 1 - i)) & 32'h00000001 );
    end
  endfunction

  reg [31:0] poly_r;
  // Persistent cfg bits used after setup: {xor_ones, refout, refin, width_m1}
  reg [6:0]  cfg_r;
  reg [5:0]  width_r;
  reg [31:0] width_mask_r;
  reg [31:0] state;

  always @(posedge clk) begin
    if (!rst_n) begin
      crc <= 32'b0;
      state <= 32'b0;
      poly_r <= 32'b0;
      cfg_r <= 7'b0;
      width_r <= 6'b0;
      width_mask_r <= 32'b0;
    end else if (setup) begin
      cfg_r <= cfg[6:0];
      width_r <= {1'b0, width};
      width_mask_r <= {16'b0, width_mask};
      poly_r <= {16'b0, poly & width_mask};
      state <= init_ones ? {16'b0, width_mask} : 32'b0;
      crc <= init_ones ? {16'b0, width_mask} : 32'b0;
    end else if (setup32) begin
      cfg_r <= 7'b1111111;
      width_r <= 6'd32;
      width_mask_r <= 32'hFFFFFFFF;
      poly_r <= CRC32_POLY;
      state <= 32'hFFFFFFFF;
      crc <= 32'hFFFFFFFF;
    end else if (feed) begin
      begin : feed_block
        reg [31:0] c;
        reg [7:0] b;
        integer i;
        reg top;
        reg [5:0] top_shift;
        top_shift = width_r - 6'd1;
        c = state;
        b = cfg_r[4] ? rev8(feed_byte) : feed_byte;
        for (i = 0; i < 8; i = i + 1) begin
          top = |( (c >> top_shift) & 32'h00000001 )
              ^ |( ( {24'h000000, b} >> (7 - i) ) & 32'h00000001 );
          c = ({c[30:0], 1'b0}) & width_mask_r;
          if (top)
            c = (c ^ poly_r) & width_mask_r;
        end
        state <= c;
        crc <= c;
      end
    end else if (finalize) begin
      begin : fin_block
        reg [31:0] out_v;
        out_v = state;
        if (cfg_r[5])
          out_v = rev_w(out_v, width_r);
        if (cfg_r[6])
          out_v = out_v ^ width_mask_r;
        crc <= out_v & width_mask_r;
      end
    end
  end
endmodule

`default_nettype wire
