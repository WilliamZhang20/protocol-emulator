`default_nettype none

// Spatial fabric CRC tile: a bit-serial LFSR of width 1..32 with any
// polynomial, fed in wire order. It absorbs a data line, can shift out its
// complemented register MSB first (appending the FCS of USB, CAN, Ethernet
// and similar), and compares the register with a check residue.
//
// Registers (16-bit, written by the controller):
//   0/1 polynomial [15:0] / [31:16]
//   2/3 check residue [15:0] / [31:16]
//   4   [5:0] absorb line  [10:6] data level (signal space 32-63)
//   5   [5:0] emit line    [10:6] init pulse line (signal space 0-31)
//   6   [4:0] width-1      [5] init to all ones
//   7   [4:0] absorb gate level  [5] absorb gated
//       [10:6] emit gate level   [11] emit gated
//
// A gated absorb or emit acts only while its gate level (signal space
// 32-63) is high, so a raw timer edge can step the register in the same
// cycle as the shifter it serves; gating the edge in a logic cell instead
// would cost that cell's register cycle.
// `ok` is registered (it reflects the register one cycle earlier) so the
// 32-bit compare never sits in front of a signal-space select.
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
  reg [10:0] absorb_cfg;
  reg [10:0] emit_cfg;
  reg [5:0]  shape;
  reg [11:0] gate_cfg;
  reg [31:0] crc;
  reg        ok_r;

  // The width mask and top-bit select depend only on the shape register, so
  // they are registered alongside it rather than decoded every cycle.
  wire        shape_we   = cfg_we && cfg_addr == 3'd6;
  wire [4:0]  width_next = shape_we ? cfg_data[4:0] : shape[4:0];
  reg  [31:0] mask;
  reg  [31:0] top;
  always @(posedge clk) begin
    if (!rst_n) begin
      mask <= 32'd1;
      top  <= 32'd1;
    end else begin
      mask <= 32'hffffffff >> (5'd31 - width_next);
      top  <= 32'd1 << width_next;
    end
  end
  wire msb = |(crc & top);
  wire feedback = msb ^ lines[{1'b1, absorb_cfg[10:6]}];
  wire [31:0] shifted = crc << 1;
  wire absorb_now = lines[absorb_cfg[5:0]] &&
                    (!gate_cfg[5] || lines[{1'b1, gate_cfg[4:0]}]);
  wire emit_now   = lines[emit_cfg[5:0]] &&
                    (!gate_cfg[11] || lines[{1'b1, gate_cfg[10:6]}]);

  assign out   = !msb;
  assign ok    = ok_r;
  assign value = crc;

  always @(posedge clk) begin
    if (!rst_n) begin
      poly       <= 32'd0;
      check      <= 32'd0;
      absorb_cfg <= 11'd0;
      emit_cfg   <= 11'd0;
      shape      <= 6'd0;
      gate_cfg   <= 12'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        3'd0: poly[15:0]  <= cfg_data;
        3'd1: poly[31:16] <= cfg_data;
        3'd2: check[15:0]  <= cfg_data;
        3'd3: check[31:16] <= cfg_data;
        3'd4: absorb_cfg <= cfg_data[10:0];
        3'd5: emit_cfg   <= cfg_data[10:0];
        3'd6: shape      <= cfg_data[5:0];
        default: gate_cfg   <= cfg_data[11:0];   // 3'd7
      endcase
    end
  end

  always @(posedge clk) begin
    if (!rst_n)
      ok_r <= 1'b0;
    else
      ok_r <= ((crc ^ check) & mask) == 32'd0;
  end

  always @(posedge clk) begin
    if (!rst_n)
      crc <= 32'd0;
    else if (!enable || lines[{1'b0, emit_cfg[10:6]}])
      crc <= shape[5] ? mask : 32'd0;
    else if (absorb_now)
      crc <= (shifted ^ (feedback ? poly : 32'd0)) & mask;
    else if (emit_now)
      crc <= shifted & mask;
  end
endmodule

`default_nettype wire
