`default_nettype none

// Programmable CRC datapath (protocol-neutral). Width 1..16, poly/init,
// reflect-in on feed, reflect-out/xor applied only when `finalize` pulses.
module crc_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        setup,
    input  wire [7:0]  cfg,
    input  wire [15:0] poly,
    input  wire        feed,
    input  wire [7:0]  feed_byte,
    input  wire        finalize,
    output reg  [15:0] crc,
    output wire        busy
);
  // cfg: {init_ones, xor_ones, refout, refin, width_m1[3:0]}
  wire [3:0] width_m1 = cfg[3:0];
  wire       refin = cfg[4];
  wire       refout = cfg[5];
  wire       xor_ones = cfg[6];
  wire       init_ones = cfg[7];
  wire [4:0] width = {1'b0, width_m1} + 5'd1;
  wire [15:0] width_mask = (width == 5'd16) ? 16'hFFFF :
                           (16'hFFFF >> (5'd16 - width));

  assign busy = 1'b0;

  function automatic [7:0] rev8(input [7:0] v);
    integer i;
    begin
      for (i = 0; i < 8; i = i + 1)
        rev8[i] = v[7 - i];
    end
  endfunction

  function automatic [15:0] rev_w(input [15:0] v, input [4:0] w);
    integer i;
    integer wi;
    begin
      rev_w = 16'b0;
      wi = {27'd0, w};
      for (i = 0; i < 16; i = i + 1)
        if (i < wi)
          rev_w[i] = v[wi - 1 - i];
    end
  endfunction

  reg [15:0] poly_r;
  reg [7:0]  cfg_r;
  reg [15:0] width_mask_r;
  reg [15:0] state;

  always @(posedge clk) begin
    if (!rst_n) begin
      crc <= 16'b0;
      state <= 16'b0;
      poly_r <= 16'b0;
      cfg_r <= 8'b0;
      width_mask_r <= 16'b0;
    end else if (setup) begin
      cfg_r <= cfg;
      width_mask_r <= width_mask;
      poly_r <= poly & width_mask;
      state <= init_ones ? width_mask : 16'b0;
      crc <= init_ones ? width_mask : 16'b0;
    end else if (feed) begin
      begin : feed_block
        reg [15:0] c;
        reg [7:0] b;
        integer i;
        reg top;
        c = state;
        b = cfg_r[4] ? rev8(feed_byte) : feed_byte;
        for (i = 0; i < 8; i = i + 1) begin
          top = c[cfg_r[3:0]] ^ b[7 - i];
          c = ({c[14:0], 1'b0}) & width_mask_r;
          if (top)
            c = (c ^ poly_r) & width_mask_r;
        end
        state <= c;
        crc <= c;
      end
    end else if (finalize) begin
      begin : fin_block
        reg [15:0] out_v;
        out_v = state;
        if (cfg_r[5])
          out_v = rev_w(out_v, {1'b0, cfg_r[3:0]} + 5'd1);
        if (cfg_r[6])
          out_v = out_v ^ width_mask_r;
        crc <= out_v & width_mask_r;
      end
    end
  end
endmodule

`default_nettype wire
