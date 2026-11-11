`default_nettype none

// Spatial fabric edge cell: one pulse line from one synchronized pin. It
// fires on the pin's rising edge, falling edge or both, optionally only
// while a qualifying level is high (or low): an I2C START is "SDA falls
// while SCL is high", a USB or Manchester receiver wants "any edge of D+".
// Eight cells replace the sixteen fixed rise/fall lines, so each pin edge a
// program uses costs one line and the rest of the pulse space is free.
//
// Register (12-bit, written by the controller; one configuration, like the
// CRC and byte tiles):
//   [2:0] pin  [3] rising  [4] falling
//   [9:5] qualifying level (signal space 32-63)  [10] qualified
//   [11] qualify on the level being low
//
// The cell is combinational from registers (the pin synchronizer, its
// previous value and the signal-space levels); the core registers its
// output into the pulse line, so the line is a register output like every
// other one.
module fabric_edge (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cfg_we,
    input  wire [11:0] cfg_data,
    input  wire [7:0]  pin_now,
    input  wire [7:0]  pin_prev,
    input  wire [31:0] levels,       // signal space 32-63
    output wire        pulse
);
  reg [11:0] cfg;
  always @(posedge clk) begin
    if (!rst_n)
      cfg <= 12'd0;
    else if (cfg_we)
      cfg <= cfg_data;
  end

  wire now  = pin_now[cfg[2:0]];
  wire prev = pin_prev[cfg[2:0]];
  wire edge_seen = (cfg[3] && now && !prev) || (cfg[4] && !now && prev);
  wire qualified = !cfg[10] || (levels[cfg[9:5]] ^ cfg[11]);
  assign pulse = edge_seen && qualified;
endmodule

`default_nettype wire
