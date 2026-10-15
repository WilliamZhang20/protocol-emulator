`default_nettype none

// Spatial fabric CRC tile: a bit-serial LFSR of width 1..32 with any
// polynomial, fed in wire order. It absorbs a data line, can shift out its
// complemented register MSB first (appending the FCS of USB, CAN, Ethernet
// and similar), and compares the register with a check residue.
//
// Registers (16-bit, written by the controller):
//   0/1 polynomial [15:0] / [31:16]
//   2/3 check residue [15:0] / [31:16]
//   4   [5:0] absorb line  [11:6] data line
//   5   [5:0] emit line    [11:6] init line
//   6   [4:0] width-1      [5] init to all ones
//
// Priority per cycle: init, absorb, emit. While the fabric is disarmed the
// register holds its init value, so a frame needs no explicit init pulse.
module fabric_crc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [2:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [63:0] lines,
    output wire        out,
    output wire        ok,
    output wire [31:0] value
);
  reg [31:0] poly;
  reg [31:0] check;
  reg [11:0] absorb_cfg;
  reg [11:0] emit_cfg;
  reg [5:0]  shape;
  reg [31:0] crc;

  wire [31:0] mask = 32'hffffffff >> (5'd31 - shape[4:0]);
  wire msb = crc[shape[4:0]];
  wire feedback = msb ^ lines[absorb_cfg[11:6]];
  wire [31:0] shifted = crc << 1;

  assign out   = !msb;
  assign ok    = ((crc ^ check) & mask) == 32'd0;
  assign value = crc;

  always @(posedge clk) begin
    if (!rst_n) begin
      poly       <= 32'd0;
      check      <= 32'd0;
      absorb_cfg <= 12'd0;
      emit_cfg   <= 12'd0;
      shape      <= 6'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        3'd0: poly[15:0]  <= cfg_data;
        3'd1: poly[31:16] <= cfg_data;
        3'd2: check[15:0]  <= cfg_data;
        3'd3: check[31:16] <= cfg_data;
        3'd4: absorb_cfg <= cfg_data[11:0];
        3'd5: emit_cfg   <= cfg_data[11:0];
        3'd6: shape      <= cfg_data[5:0];
        default: begin end
      endcase
    end
  end

  always @(posedge clk) begin
    if (!rst_n)
      crc <= 32'd0;
    else if (!enable || lines[emit_cfg[11:6]])
      crc <= shape[5] ? mask : 32'd0;
    else if (lines[absorb_cfg[5:0]])
      crc <= (shifted ^ (feedback ? poly : 32'd0)) & mask;
    else if (lines[emit_cfg[5:0]])
      crc <= shifted & mask;
  end
endmodule

`default_nettype wire
