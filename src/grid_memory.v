`default_nettype none
module grid_word_link #(parameter WIDTH=20)(input wire [WIDTH-1:0] in,output wire [WIDTH-1:0] out);
  assign out=in;
endmodule
// A local single-port SRAM tile with host/actor round-robin arbitration.
module grid_sram_tile #(parameter USE_MACRO=0)(
  input wire clk,rst_n,arm,
  input wire [1:0] req,we,input wire [19:0] addr,input wire [15:0] wdata,
  output wire [1:0] ready,output reg [1:0] rvalid,output wire [15:0] rdata);
  reg next_priority;
  wire [1:0] candidates=req & {2{arm && rst_n}};
  wire [1:0] grant=candidates==2'b11 ? (next_priority ? 2'b10 : 2'b01) : candidates;
  wire [7:0] read_data;
  assign ready=grant;
  assign rdata={read_data,read_data};
  experiment_memory_bank #(.USE_MACRO(USE_MACRO)) bank(clk,|grant,|(grant & we),
    grant[1] ? addr[19:10] : addr[9:0],grant[1] ? wdata[15:8] : wdata[7:0],read_data);
  always @(posedge clk) begin
    if(!rst_n) begin next_priority<=0;rvalid<=0;end
    else begin rvalid<=grant & ~we;if(|grant) next_priority<=grant[0];end
  end
endmodule

// Host reaches both distributed banks. The actor port is at the shifter cell;
// its word bus reaches SRAM0 on the south edge and SRAM1 across the bottom
// row via a dedicated, non-switchable word link. Only the bank choice is
// configurable: this is not yet a general word-wide mesh.
module grid_memory #(parameter USE_MACRO=0)(
  input wire clk,rst_n,arm,cfg_we,input wire [1:0] cfg_routes,
  input wire [1:0] req,we,input wire [19:0] addr,input wire [15:0] wdata,
  output wire [1:0] ready,rvalid,output wire [15:0] rdata);
  reg [1:0] routes;
  wire [19:0] actor6,actor7,actor8;
  // Explicit point-to-point bus segments: shifter (1,0) -> SRAM (2,0)
  // -> shifter/word relay (2,1) -> SRAM (2,2).
  grid_word_link shift_to_sram0({req[1],we[1],addr[19:10],wdata[15:8]},actor6);
  grid_word_link sram0_to_route(actor6,actor7);
  grid_word_link route_to_sram1(actor7,actor8);
  wire [1:0] q0={actor6[19] && !routes[1],req[0] && !routes[0]};
  wire [1:0] q1={actor8[19] && routes[1],req[0] && routes[0]};
  wire [1:0] ready0,ready1,valid0,valid1;
  wire [15:0] data0,data1;
  wire [9:0] return0,return1a,return1b,return1;
  grid_sram_tile #(.USE_MACRO(USE_MACRO)) row2_col0(clk,rst_n,arm,q0,{actor6[18],we[0]},
    {actor6[17:8],addr[9:0]},{actor6[7:0],wdata[7:0]},ready0,valid0,data0);
  grid_sram_tile #(.USE_MACRO(USE_MACRO)) row2_col2(clk,rst_n,arm,q1,{actor8[18],we[0]},
    {actor8[17:8],addr[9:0]},{actor8[7:0],wdata[7:0]},ready1,valid1,data1);
  grid_word_link #(.WIDTH(10)) sram0_to_shift({ready0[1],valid0[1],data0[15:8]},return0);
  grid_word_link #(.WIDTH(10)) sram1_to_route({ready1[1],valid1[1],data1[15:8]},return1a);
  grid_word_link #(.WIDTH(10)) route_to_sram0(return1a,return1b);
  grid_word_link #(.WIDTH(10)) sram0_to_shift_other(return1b,return1);
  assign ready={return0[9]|return1[9],ready0[0]|ready1[0]};
  assign rvalid={return0[8]|return1[8],valid0[0]|valid1[0]};
  assign rdata[7:0]=valid1[0] ? data1[7:0] : data0[7:0];
  assign rdata[15:8]=return1[8] ? return1[7:0] : return0[7:0];
  always @(posedge clk) begin
    if(!rst_n) routes<=0;
    else if(!arm && cfg_we) routes<=cfg_routes;
  end
endmodule
`default_nettype wire
