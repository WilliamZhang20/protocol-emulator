`timescale 1ns/1ps
`default_nettype none
// I2C target (compiler lanes/i2c_target.lane) on the two-event sequencer
// prototype, at the bit level: an I2C controller model on open-drain SCL
// and SDA, 2-flop synchronisers with registered edge pulses (the proposed
// sink edge modes), a shift stand-in for the coded shifter (start on a1,
// sample SDA on each SCL rise, a one-clock word pulse after 8 bits), the
// word-path compare (match = rx word == 0x90, a level) and the writer gate
// (a word pulse with a3 high pushes the byte).
//
// Plusargs: +HALF=n (clocks per SCL half period), +SETUP=n (clocks between an
// SDA change and the next SCL rise), +HOLD=n (clocks between an SCL fall and
// the next SDA change). Exit status 0 only if every check passes.
module tb;
  parameter LATCH=0;
  // QUAL=1: START and STOP come from a LUT4 + register cell (SDA edge while
  // SCL high, sampled in the same clock); program B below. QUAL=0: the
  // lane program's shape (an SDA edge, then a row that checks SCL), program A.
  parameter QUAL=0;
  reg clk=0; always #1 clk=!clk;
  reg rst_n=0;
  reg scl_m=1, sda_m=1;
  wire [3:0] act;
  wire sda=sda_m && !act[0];
  wire scl=scl_m;
  reg [1:0] scl_s=3, sda_s=3; reg scl_p=1, sda_p=1;
  reg scl_rise=0, scl_fall=0, sda_rise=0, sda_fall=0;
  always @(posedge clk) begin
    scl_s<={scl_s[0],scl}; sda_s<={sda_s[0],sda};
    scl_p<=scl_s[1]; sda_p<=sda_s[1];
    scl_rise<=scl_s[1] && !scl_p; scl_fall<=!scl_s[1] && scl_p;
    sda_rise<=sda_s[1] && !sda_p; sda_fall<=!sda_s[1] && sda_p;
  end
  // Coder stand-in.
  reg armed=0, word=0; reg [3:0] cnt=0; reg [7:0] sh=0, rx=0; reg a1_q=0;
  always @(posedge clk) begin
    word<=0; a1_q<=act[1];
    if(act[1] && !a1_q) begin armed<=1;cnt<=0;end
    else if(armed && scl_rise) begin
      sh<={sh[6:0],sda_s[1]}; cnt<=cnt+1;
      if(cnt==7) begin rx<={sh[6:0],sda_s[1]};word<=1;armed<=0;end
    end
  end
  wire match=rx==8'h90;
  // Writer gate.
  reg [7:0] pushed[0:15]; integer npushed=0;
  always @(posedge clk) if(word && act[3]) begin pushed[npushed]<=rx;npushed<=npushed+1;end
  // LUT4 + register: inputs SDA, SDA delayed, SCL (all routed levels).
  reg start_q=0, stop_q=0;
  always @(posedge clk) begin
    start_q<=!sda_s[1] && sda_p && scl_s[1];
    stop_q<=sda_s[1] && !sda_p && scl_s[1];
  end
  // Events. QUAL=0: 1 SCL level, 2 SDA level, 3 SCL fall, 4 SDA fall,
  // 5 SDA rise, 6 word, 7 match. QUAL=1: 4 START, 5 STOP instead.
  wire [7:1] ev=QUAL ? {match,word,stop_q,start_q,scl_fall,sda_s[1],scl_s[1]}
                     : {match,word,sda_rise,sda_fall,scl_fall,sda_s[1],scl_s[1]};
  reg cfg_we=0; reg [3:0] cfg_addr=0; reg [18:0] cfg_data=0; reg start=0, enable=0;
  wire active, done, error; wire [3:0] state;
  seq2 #(.LATCH(LATCH)) dut(clk,rst_n,enable,cfg_we,cfg_addr,cfg_data,start,4'd0,4'd0,ev,act,active,done,error,state);
  function [18:0] R(input h, input [3:0] a, input [2:0] ea, input [3:0] na, input [2:0] eb, input [3:0] nb);
    R={h,a,ea,na,eb,nb};
  endfunction
  localparam ALW=0, SCLL=1, SDAL=2, SCLF=3, SDAF=4, SDAR=5, WORD=6, MATCH=7;
  localparam START=4, STOP=5;
  integer i;
  reg [18:0] prog[0:15];
  integer IDLE_ROW;
  initial if(QUAL) begin
    // Program B: 13 rows.
    IDLE_ROW=2;
    for(i=0;i<16;i=i+1) prog[i]=R(1,4'b0100,ALW,0,ALW,0);   // unused: halt with error
    prog[0]=R(0,4'b0000,SDAL,1,SDAL,1);
    prog[1]=R(0,4'b0000,SCLL,2,SCLL,2);
    prog[2]=R(0,4'b0000,START,4,START,4);
    prog[4]=R(0,4'b0010,ALW,5,ALW,5);
    prog[5]=R(0,4'b0000,WORD,6,WORD,6);
    prog[6]=R(0,4'b0000,MATCH,7,ALW,11);
    prog[7]=R(0,4'b1000,SCLF,8,SCLF,8);
    prog[8]=R(0,4'b1001,SCLL,9,SCLL,9);
    prog[9]=R(0,4'b1001,SCLF,10,SCLF,10);
    prog[10]=R(0,4'b1010,ALW,12,ALW,12);
    prog[11]=R(0,4'b0000,STOP,0,START,4);
    prog[12]=R(0,4'b1000,WORD,7,STOP,15);
    prog[15]=R(1,4'b0000,ALW,15,ALW,15);
  end else begin
    IDLE_ROW=2;
    prog[0]=R(0,4'b0000,SDAL,1,SDAL,1);
    prog[1]=R(0,4'b0000,SCLL,2,SCLL,2);
    prog[2]=R(0,4'b0000,SDAF,3,SDAF,3);
    prog[3]=R(0,4'b0000,SCLL,4,ALW,0);
    prog[4]=R(0,4'b0010,ALW,5,ALW,5);
    prog[5]=R(0,4'b0000,WORD,6,WORD,6);
    prog[6]=R(0,4'b0000,MATCH,7,ALW,11);
    prog[7]=R(0,4'b1000,SCLF,8,SCLF,8);
    prog[8]=R(0,4'b1001,SCLL,9,SCLL,9);
    prog[9]=R(0,4'b1001,SCLF,10,SCLF,10);
    prog[10]=R(0,4'b1010,ALW,12,ALW,12);
    prog[11]=R(0,4'b0000,SDAR,14,SDAR,14);
    prog[12]=R(0,4'b1000,WORD,7,SDAR,13);
    prog[13]=R(0,4'b1000,SCLL,15,ALW,12);
    prog[14]=R(0,4'b0000,SCLL,0,ALW,11);
    prog[15]=R(1,4'b0000,ALW,15,ALW,15);
  end
  integer HALF=40, SETUP=10, HOLD=10, fails=0, acks;
  task wait_clk(input integer n); repeat(n) @(posedge clk); endtask
  // A bit: SDA changes HOLD clocks after SCL fell, SCL rises SETUP clocks
  // later, stays high HALF clocks, falls.
  task clock_bit(input b, output seen);
    begin
      wait_clk(HOLD); sda_m=b; wait_clk(SETUP); scl_m=1; wait_clk(HALF/2);
      seen=sda; wait_clk(HALF-HALF/2); scl_m=0;
    end
  endtask
  task start_cond; begin sda_m=1; wait_clk(HALF); scl_m=1; wait_clk(HALF); sda_m=0; wait_clk(HALF); scl_m=0; end endtask
  task stop_cond; begin wait_clk(HOLD); sda_m=0; wait_clk(SETUP); scl_m=1; wait_clk(HALF); sda_m=1; wait_clk(HALF); end endtask
  task write_byte(input [7:0] v, output ack);
    reg seen; integer k;
    begin
      for(k=7;k>=0;k=k-1) begin clock_bit(v[k],seen); if(seen!==v[k]) begin $display("FAIL: SDA disturbed in a data bit");fails=fails+1;end end
      clock_bit(1,seen); ack=!seen;
    end
  endtask
  reg [7:0] payload[0:3]; reg ack;
  initial begin
    if(!$value$plusargs("HALF=%d",HALF)) HALF=40;
    if(!$value$plusargs("SETUP=%d",SETUP)) SETUP=10;
    if(!$value$plusargs("HOLD=%d",HOLD)) HOLD=10;
    payload[0]=8'h12; payload[1]=8'ha5; payload[2]=8'h00; payload[3]=8'hff;
    wait_clk(3); rst_n=1;
    for(i=0;i<16;i=i+1) begin @(negedge clk); cfg_we=1; cfg_addr=i; cfg_data=prog[i]; end
    @(negedge clk); cfg_we=0; enable=1; start=1; @(negedge clk); start=0;
    wait_clk(HALF);
    // 1. A write to another address (0x50): no ACK; the target returns to free.
    start_cond; write_byte(8'ha0,ack);
    if(ack) begin $display("FAIL: ACKed address 0x50");fails=fails+1;end
    stop_cond; wait_clk(8);   // the STOP pulse crosses the synchroniser and edge register
    if(!active || state!=IDLE_ROW) begin $display("FAIL: not back at idle after another address (state %0d)",state);fails=fails+1;end
    // 2. A write to 0x48 with four bytes: every byte ACKed and pushed, the
    // address byte not pushed; STOP right after the last ACK halts cleanly.
    start_cond; write_byte(8'h90,ack); acks=ack;
    for(i=0;i<4;i=i+1) begin write_byte(payload[i],ack); acks=acks+ack; end
    stop_cond; wait_clk(10);
    if(acks!=5) begin $display("FAIL: %0d of 5 ACKs",acks);fails=fails+1;end
    if(npushed!=4) begin $display("FAIL: %0d bytes pushed",npushed);fails=fails+1;end
    else for(i=0;i<4;i=i+1) if(pushed[i]!==payload[i]) begin $display("FAIL: byte %0d %h",i,pushed[i]);fails=fails+1;end
    if(active || error) begin $display("FAIL: not halted cleanly (active %b error %b state %0d)",active,error,state);fails=fails+1;end
    if(fails==0) $display("PASS QUAL=%0d LATCH=%0d HALF=%0d SETUP=%0d HOLD=%0d",QUAL,LATCH,HALF,SETUP,HOLD);
    else $display("FAILED QUAL=%0d LATCH=%0d HALF=%0d SETUP=%0d HOLD=%0d (%0d)",QUAL,LATCH,HALF,SETUP,HOLD,fails);
    $finish(fails!=0);
  end
  initial begin #2000000; $display("FAIL: timeout");$finish(1); end
endmodule
`default_nettype wire
module trace;
  reg [3:0] last=15;
  always @(posedge tb.clk) if($test$plusargs("TRACE") && (tb.state!=last || tb.word || tb.scl_rise)) begin
    last<=tb.state;
    $display("%0d st=%0d act=%b scl=%b sda=%b rise=%b word=%b armed=%b cnt=%0d", $time/2, tb.state, tb.act, tb.scl, tb.sda, tb.scl_rise, tb.word, tb.armed, tb.cnt);
  end
endmodule
