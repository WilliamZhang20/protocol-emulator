`default_nettype none
module grid_stream_link #(parameter WIDTH=20)(input wire [WIDTH-1:0] in,output wire [WIDTH-1:0] out);
  assign out=in;
endmodule
// Three clients (host, reader, writer), round-robin per single-port bank.
// Each client is statically assigned to one bank while disarmed. Read returns
// are tagged by grant, ordered per client and have no response backpressure.
module grid_stream_bank #(parameter USE_MACRO=0)(
  input wire clk,rst_n,enable,input wire [2:0] req,we,
  input wire [29:0] addr,input wire [23:0] wdata,
  output reg [2:0] ready,output reg [2:0] rvalid,output wire [7:0] rdata);
  reg [1:0] next_priority;reg [1:0] choice;reg found;
  integer k;integer candidate;
  always @* begin
    ready=0;choice=0;found=0;
    for(k=0;k<3;k=k+1) begin
      candidate={30'b0,next_priority}+k;
      if(candidate>=3) candidate=candidate-3;
      if(!found && req[candidate] && enable && rst_n) begin
        ready[candidate]=1;choice=candidate[1:0];found=1;
      end
    end
  end
  wire [9:0] selected_addr=choice==0 ? addr[9:0] : choice==1 ? addr[19:10] : addr[29:20];
  wire [7:0] selected_data=choice==0 ? wdata[7:0] : choice==1 ? wdata[15:8] : wdata[23:16];
  wire selected_we=|(ready & we);
  experiment_memory_bank #(.USE_MACRO(USE_MACRO)) bank(clk,|ready,selected_we,selected_addr,selected_data,rdata);
  always @(posedge clk) begin
    if(!rst_n) begin next_priority<=0;rvalid<=0;end
    else begin
      rvalid<=ready & ~we;
      if(|ready) next_priority<=choice==2 ? 0 : choice+1'b1;
    end
  end
endmodule

module grid_stream_memory #(parameter USE_MACRO=0)(
  input wire clk,rst_n,enable,cfg_we,input wire [2:0] cfg_routes,input wire [1:0] stream_banks,
  input wire [2:0] req,we,input wire [29:0] addr,input wire [23:0] wdata,
  output wire [2:0] ready,rvalid,output wire [23:0] rdata);
  reg [2:0] routes;
  wire [2:0] ready0,ready1,valid0,valid1;
  wire [7:0] data0,data1;
  wire [19:0] reader0,reader_mid,reader1,writer0,writer_mid,writer1;
  // The reader is adjacent to bank 0 and the writer to bank 1. A stream
  // assigned to the other bank crosses the intervening bottom-row cell.
  grid_stream_link reader_to_bank0({req[1],we[1],addr[19:10],wdata[15:8]},reader0);
  grid_stream_link reader_to_middle(reader0,reader_mid);
  grid_stream_link reader_to_bank1(reader_mid,reader1);
  grid_stream_link writer_to_bank1({req[2],we[2],addr[29:20],wdata[23:16]},writer1);
  grid_stream_link writer_to_middle(writer1,writer_mid);
  grid_stream_link writer_to_bank0(writer_mid,writer0);
  grid_stream_bank #(.USE_MACRO(USE_MACRO)) row2_col0(clk,rst_n,enable,
    {writer0[19] && !stream_banks[1],reader0[19] && !stream_banks[0],req[0] && !routes[0]},
    {writer0[18],reader0[18],we[0]},{writer0[17:8],reader0[17:8],addr[9:0]},
    {writer0[7:0],reader0[7:0],wdata[7:0]},ready0,valid0,data0);
  grid_stream_bank #(.USE_MACRO(USE_MACRO)) row2_col2(clk,rst_n,enable,
    {writer1[19] && stream_banks[1],reader1[19] && stream_banks[0],req[0] && routes[0]},
    {writer1[18],reader1[18],we[0]},{writer1[17:8],reader1[17:8],addr[9:0]},
    {writer1[7:0],reader1[7:0],wdata[7:0]},ready1,valid1,data1);
  wire [9:0] r0,r1a,r1b,r1,w0a,w0b,w0,w1;
  grid_stream_link #(.WIDTH(10)) bank0_to_reader({ready0[1],valid0[1],data0},r0);
  grid_stream_link #(.WIDTH(10)) bank1_to_middle({ready1[1],valid1[1],data1},r1a);
  grid_stream_link #(.WIDTH(10)) middle_to_bank0(r1a,r1b);
  grid_stream_link #(.WIDTH(10)) bank0_to_reader_from1(r1b,r1);
  grid_stream_link #(.WIDTH(10)) bank0_to_middle_writer({ready0[2],valid0[2],data0},w0a);
  grid_stream_link #(.WIDTH(10)) middle_to_bank1_writer(w0a,w0b);
  grid_stream_link #(.WIDTH(10)) bank1_to_writer_from0(w0b,w0);
  grid_stream_link #(.WIDTH(10)) bank1_to_writer({ready1[2],valid1[2],data1},w1);
  assign ready={w0[9]|w1[9],r0[9]|r1[9],ready0[0]|ready1[0]};
  assign rvalid={w0[8]|w1[8],r0[8]|r1[8],valid0[0]|valid1[0]};
  assign rdata[7:0]=valid1[0] ? data1 : data0;
  assign rdata[15:8]=r1[8] ? r1[7:0] : r0[7:0];
  assign rdata[23:16]=w1[8] ? w1[7:0] : w0[7:0];
  always @(posedge clk) begin
    if(!rst_n) routes<=0;
    else if(!enable && cfg_we) routes<=cfg_routes;
  end
endmodule
`default_nettype wire
