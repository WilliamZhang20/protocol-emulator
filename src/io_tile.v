`default_nettype none
// I/O tile (Active plan): synchronised pins; 4 registered outputs, each any
// pin's level, rise or fall, optionally qualified by another pin's level
// (I2C START = SDA fall while SCL high; SPI SCK edge while CS low).
// Output k config (10 bits): {qual_pol[9], qual_en[8], qual_pin[7:5],
// mode[4:3] (0 level, 1 rise, 2 fall, 3 host event pin[1:0]), pin[2:0]}.
// A host event is a one-clock pulse the host fires before or between
// transactions (FABRIC_REORG.md step 4 L3); it enters the mesh here like a
// pin edge. Pin drive: value/enable come from the cell's sinks (open drain:
// value 0, enable = pull low).
module io_tile(input wire clk, run, input wire [7:0] pins, input wire [39:0] cfg,
  output reg [3:0] out, input wire [3:0] host_ev);
  reg [7:0] m, s, p;
  always @(posedge clk) begin m<=pins; s<=m; p<=s; end
  integer k;
  always @(posedge clk) begin
    for(k=0;k<4;k=k+1) begin : o
      reg [9:0] c; reg v, q;
      c=cfg[10*k+:10];
      case(c[4:3]) 2'd0: v=s[c[2:0]]; 2'd1: v=s[c[2:0]] && !p[c[2:0]]; 2'd2: v=!s[c[2:0]] && p[c[2:0]]; default: v=host_ev[c[1:0]]===1'b1; endcase
      q=!c[8] || (s[c[7:5]]==!c[9]);
      out[k]<=run && v && q;
    end
  end
endmodule
`default_nettype wire
