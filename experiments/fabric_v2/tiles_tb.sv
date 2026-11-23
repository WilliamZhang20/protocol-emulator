`timescale 1ns/1ps
// Standalone RTL-only tile test. No internal cocotb hierarchy access.
module tiles_tb;
  reg clk=0,rst_n=0,arm=0,cfg_we=0,start=0,stop=0,hold=0;
  reg [15:0] first=0,period=0;
  wire tick,running,configured;
  wire level,rise,fall;
  fabric_v2_timer timer(clk,rst_n,arm,cfg_we,first,period,start,stop,hold,tick,running,configured,level,rise,fall);
  reg s_start=0,shift=0,sample=0,msb=0,serial_in=0;
  reg [4:0] width=0;
  reg [15:0] tx=0;
  wire serial_out,busy,done;
  wire [15:0] rx;
  fabric_v2_shift shifter(clk,rst_n,arm,s_start,shift,sample,width,msb,tx,serial_in,serial_out,rx,busy,done);
  always #5 clk=~clk;
  task automatic cycle;
    begin @(posedge clk); #1; @(negedge clk); end
  endtask
  task automatic transfer(input integer n,input bit order,input reg [15:0] send,input reg [15:0] recv);
    integer i,idx;
    begin
      width=5'(n); msb=order;tx=send;s_start=1;cycle();s_start=0;
      if (!busy) $fatal(1,"shift did not start n=%0d",n);
      for (i=0;i<n;i=i+1) begin
        idx=order ? n-1-i : i;
        if (serial_out!==send[idx]) $fatal(1,"TX n=%0d order=%0d bit=%0d",n,order,i);
        serial_in=recv[idx];sample=1;cycle();sample=0;
        shift=1;cycle();shift=0;
        if (i<n-1 && (!busy || done)) $fatal(1,"early done");
      end
      if (busy || !done || (rx & (16'hffff >> (16-n))) !== (recv & (16'hffff >> (16-n))))
        $fatal(1,"RX n=%0d order=%0d got=%h want=%h",n,order,rx,recv);
      cycle(); if (done) $fatal(1,"done not a pulse");
    end
  endtask
  integer n;
  initial begin
    @(negedge clk); cycle();rst_n=1;
    first=3;period=4;cfg_we=1;cycle();cfg_we=0;
    if (!configured) $fatal(1,"timer config invalid");
    arm=1;start=1;cycle();start=0;
    cycle();if (tick) $fatal(1,"early first tick 1");
    hold=1;repeat(3) begin cycle();if (tick) $fatal(1,"tick while held");end
    hold=0;cycle();if (tick) $fatal(1,"early first tick 2");
    cycle();if (!tick) $fatal(1,"missing first tick");
    cfg_we=1;first=1;period=1;cycle();cfg_we=0;
    repeat(2) begin cycle();if (tick) $fatal(1,"period changed while armed");end
    cycle();if (!tick) $fatal(1,"missing repeat tick");
    stop=1;cycle();stop=0;if (running || tick) $fatal(1,"stop failed");
    for (n=1;n<=16;n=n+1) begin
      transfer(n,0,16'ha5c3,16'h5a3c);
      transfer(n,1,16'ha5c3,16'h5a3c);
    end
    width=0;s_start=1;cycle();s_start=0;if (busy) $fatal(1,"accepted width zero");
    width=17;s_start=1;cycle();s_start=0;if (busy) $fatal(1,"accepted width 17");
    arm=0;cycle(); if (busy || running || tick) $fatal(1,"disarm failed");
    first=0;period=4;cfg_we=1;cycle();cfg_we=0;if(configured) $fatal(1,"accepted invalid timer");
    arm=1;start=1;cycle();start=0;if(running) $fatal(1,"started unconfigured timer");
    $display("PASS: configured timer first/repeat/hold and 1..16-bit bidirectional shifters in both orders");
    $finish;
  end
endmodule
