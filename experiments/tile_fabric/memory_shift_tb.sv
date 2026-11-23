`timescale 1ns/1ps
`default_nettype none
module memory_shift_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0, host_req=0, host_we=0, start=0;
  reg [1:0] cfg_routes=0;
  reg [9:0] host_addr=0;
  reg [7:0] host_wdata=0;
  wire [1:0] ready, valid, sck, mosi, done, error, waiting;
  wire [7:0] rdata[0:1];
  genvar k;
  generate for (k=0; k<2; k=k+1) begin : implementations
    memory_shift_fabric #(.USE_MACRO(k)) dut(clk,rst_n,arm,cfg_we,cfg_routes,
        host_req,host_we,host_addr,host_wdata,ready[k],valid[k],rdata[k],
        start,5'd12,8'd4,10'd100,10'd200,1'b1,sck[k],mosi[k],done[k],error[k],waiting[k]);
  end endgenerate
  reg old_sck=0;
  reg [11:0] sent=0;
  integer bits_seen=0, stalls=0, i;
  reg completed=0;
  always @(negedge clk) begin
    if (ready[0]!==ready[1] || valid[0]!==valid[1] || sck[0]!==sck[1] ||
        mosi[0]!==mosi[1] || done[0]!==done[1] || error[0]!==error[1] || waiting[0]!==waiting[1])
      $fatal(1,"behavioral and macro-backed transfer differ");
    if (valid[0] && rdata[0]!==rdata[1]) $fatal(1,"macro read mismatch");
    if (!old_sck && sck[0]) begin sent={sent[10:0],mosi[0]}; bits_seen=bits_seen+1; end
    old_sck=sck[0];
  end
  always @(posedge clk) begin
    if (waiting[0]) stalls=stalls+1;
    if (done[0]) completed=1;
  end
  task write_byte(input [9:0] a, input [7:0] v);
    begin
      @(negedge clk); host_req=1; host_we=1; host_addr=a; host_wdata=v;
      do @(posedge clk); while (!ready[0]);
      @(negedge clk); host_req=0; host_we=0;
    end
  endtask
  task read_byte(input [9:0] a, input [7:0] expected);
    begin
      @(negedge clk); host_req=1; host_we=0; host_addr=a;
      do @(posedge clk); while (!ready[0]);
      #1; if (!valid[0] || rdata[0]!==expected) $fatal(1,"read %0d got %h expected %h",a,rdata[0],expected);
      @(negedge clk); host_req=0;
    end
  endtask
  initial begin
    repeat (3) @(negedge clk); rst_n=1;
    cfg_we=1; cfg_routes=2'b11; @(negedge clk); cfg_we=0; arm=1;
    write_byte(100,8'h0a); write_byte(101,8'h5c);
    @(negedge clk); start=1;
    @(negedge clk); start=0;
    while (bits_seen<12) @(negedge clk);
    host_req=1; host_we=1; host_addr=300; host_wdata=8'h77;
    repeat (12) @(negedge clk);
    host_req=0; host_we=0;
    i=0; while (!completed && i<400) begin @(negedge clk); i=i+1; end
    if (!completed || error[0]) $fatal(1,"transfer did not complete");
    if (stalls==0) $fatal(1,"contention did not stall transfer requester");
    if (bits_seen!=12 || sent!==12'ha5c) $fatal(1,"12-bit TX mismatch %h (%0d)",sent,bits_seen);
    read_byte(200,8'h0f); read_byte(201,8'hff); read_byte(300,8'h77);
    $display("PASS: 12-bit memory-to-shifter exchange with contention (stalls=%0d)",stalls);
    $finish;
  end
endmodule
`default_nettype wire
