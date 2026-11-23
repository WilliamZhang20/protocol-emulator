`timescale 1ns/1ps
`default_nettype none
module memory_tiles_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0;
  reg [1:0] cfg_routes=0, req=0, we=0;
  reg [19:0] addr=0;
  reg [15:0] wdata=0;
  wire [1:0] ready, rvalid, macro_ready, macro_valid;
  wire [15:0] rdata, macro_data;
  experiment_memory_fabric #(.USE_MACRO(0)) behavioral(clk,rst_n,arm,cfg_we,cfg_routes,
      req,we,addr,wdata,ready,rvalid,rdata);
  experiment_memory_fabric #(.USE_MACRO(1)) macro_backed(clk,rst_n,arm,cfg_we,cfg_routes,
      req,we,addr,wdata,macro_ready,macro_valid,macro_data);
  always @(negedge clk) begin
    if (ready !== macro_ready || rvalid !== macro_valid) $fatal(1,"macro handshake mismatch");
    if (rvalid[0] && rdata[7:0] !== macro_data[7:0]) $fatal(1,"macro data 0 mismatch");
    if (rvalid[1] && rdata[15:8] !== macro_data[15:8]) $fatal(1,"macro data 1 mismatch");
  end
  reg [1:0] first;
  initial begin
    repeat (3) @(negedge clk); rst_n=1;
    cfg_we=1; cfg_routes=2'b10; @(negedge clk); cfg_we=0; arm=1;
    req=2'b11; we=2'b11; addr={10'd7,10'd7}; wdata=16'hb2a1; #1;
    if (ready!==2'b11) $fatal(1,"independent banks must accept concurrently");
    @(negedge clk); req=0; we=0;
    // Reconfiguration while armed must be ignored.
    cfg_we=1; cfg_routes=0; @(negedge clk); cfg_we=0;
    req=2'b11; #1; if (ready!==2'b11) $fatal(1,"armed config changed routes");
    @(posedge clk); #1;
    if (rvalid!==2'b11 || rdata!==16'hb2a1) $fatal(1,"parallel synchronous reads");
    @(negedge clk); req=0;
    arm=0; cfg_we=1; cfg_routes=0; @(negedge clk); cfg_we=0; arm=1;
    req=2'b11; we=0; addr={10'd7,10'd7}; #1; first=ready;
    if (first!==2'b01 && first!==2'b10) $fatal(1,"same bank must grant exactly one");
    @(posedge clk); #1;
    if (rvalid!==first) $fatal(1,"first contested response");
    @(negedge clk); #1;
    if (ready!==(first ^ 2'b11)) $fatal(1,"round robin did not alternate");
    @(posedge clk); #1;
    if (rvalid!==(first ^ 2'b11)) $fatal(1,"second contested response");
    if ((rvalid[0] && rdata[7:0]!==8'ha1) || (rvalid[1] && rdata[15:8]!==8'ha1))
      $fatal(1,"same-bank read mismatch");
    @(negedge clk); req=0; arm=0; #1;
    if (ready!==0) $fatal(1,"disarmed fabric accepted request");
    // A read accepted before disarm still produces its one-cycle response;
    // reset clears the response token, not SRAM contents.
    @(negedge clk); arm=1; req=2'b01; we=0; addr[9:0]=7;
    @(posedge clk); #1; if (rvalid!==1 || rdata[7:0]!==8'ha1) $fatal(1,"read before disarm");
    @(negedge clk); arm=0; req=0; #1;
    if (rvalid!==1 || rdata[7:0]!==8'ha1) $fatal(1,"disarm lost accepted response");
    @(posedge clk); #1; if (rvalid!==0) $fatal(1,"read response did not expire");
    @(negedge clk); arm=1; req=1;
    @(posedge clk); #1; if (rvalid!==1) $fatal(1,"read before reset");
    @(negedge clk); rst_n=0; req=0;
    @(posedge clk); #1; if (rvalid!==0 || ready!==0) $fatal(1,"reset did not clear response");
    @(negedge clk); rst_n=1; arm=1; req=1;
    @(posedge clk); #1;
    if (rvalid!==1 || rdata[7:0]!==8'ha1) $fatal(1,"reset altered SRAM contents");
    $display("PASS: independent banks, arbitration, routing and macro/model equivalence");
    $finish;
  end
endmodule
`default_nettype wire
