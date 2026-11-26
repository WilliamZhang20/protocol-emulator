`timescale 1ns/1ps
`default_nettype none
// Compiled configuration on the mesh (FABRIC_REORG.md, criterion 3): the
// compiler (protocol-emulator-compiler circt_lab/fabric_map.py) places,
// routes and emits the I2C target and the UART receive from source; this
// bench loads that vector (+CFG=file.hex) into mesh.v and runs the same pin
// stimulus and checks as the hand-mapped slice (slice_i2c_tb.sv): the I2C
// target ACKs 0x48 and stores its data bytes, NAKs other addresses, and a
// UART byte stream on pad 2 arrives intact throughout. The bench knows no
// cell, track or context: only pads and the mesh's host ports.
// Mesh parameters come from the contract (iverilog -P).
// Plusargs: +CFG +HALF +SETUP +HOLD (clocks) +UART.
module mesh_tb #(parameter ROWS=3, COLS=3, WORD_PORT=2,
  parameter [2*ROWS*COLS-1:0] KINDS=18'b01_10_00_10_01_01_10_00_00,
  parameter [ROWS*COLS-1:0] CTX4=9'b011100111);
  localparam N=ROWS*COLS, CFG_BITS=N*512+128, WORDS=(CFG_BITS+31)/32;
  reg clk=0; always #1 clk=!clk;
  reg rst_n=0, run=0;
  reg [31:0] mem[0:WORDS-1];
  reg [CFG_BITS-1:0] cfg;
  reg scl_m=1, sda_m=1, rx_pin=1;
  wire [7:0] pull_low;
  wire scl=scl_m && !pull_low[0], sda=sda_m && !pull_low[1];
  wire [7:0] pins={5'b0,rx_pin && !pull_low[2],sda,scl};
  wire ready, wr_valid; wire [15:0] wr_data;
  wire [N-1:0] host_valid; wire [8*N-1:0] host_byte;
  mesh #(.ROWS(ROWS),.COLS(COLS),.WORD_PORT(WORD_PORT),.KINDS(KINDS),.CTX4(CTX4)) dut(
    clk,rst_n,run,cfg,pins,pull_low,ready,wr_data,wr_valid,1'b1,host_valid,host_byte);
  reg [7:0] pushed[0:31]; integer npushed=0;
  always @(posedge clk) if(wr_valid) begin pushed[npushed]<=wr_data[7:0];npushed<=npushed+1;end
  reg [7:0] u_got[0:255]; integer u_n=0, k;
  always @(posedge clk) for(k=0;k<N;k=k+1) if(host_valid[k]) begin u_got[u_n]<=host_byte[8*k+:8];u_n<=u_n+1;end
  // ---- I2C controller model (as slice_i2c_tb.sv) ----
  integer HALF=40, SETUP=10, HOLD=10, fails=0, i;
  task wait_clk(input integer n); repeat(n) @(posedge clk); endtask
  task clock_bit(input b, output seen);
    begin wait_clk(HOLD); sda_m=b; wait_clk(SETUP); scl_m=1; wait_clk(HALF/2); seen=sda; wait_clk(HALF-HALF/2); scl_m=0; end
  endtask
  task start_cond; begin sda_m=1; wait_clk(HALF); scl_m=1; wait_clk(HALF); sda_m=0; wait_clk(HALF); scl_m=0; end endtask
  task stop_cond; begin wait_clk(HOLD); sda_m=0; wait_clk(SETUP); scl_m=1; wait_clk(HALF); sda_m=1; wait_clk(HALF); end endtask
  task write_byte(input [7:0] v, output ack);
    reg seen; integer j;
    begin
      for(j=7;j>=0;j=j-1) begin clock_bit(v[j],seen); if(seen!==v[j]) begin $display("FAIL: SDA disturbed in a data bit");fails=fails+1;end end
      clock_bit(1,seen); ack=!seen;
    end
  endtask
  task write(input [7:0] addr, input integer n, input [8*8-1:0] data, output integer acks);
    reg a; integer j;
    begin
      start_cond; write_byte(addr,a); acks=a;
      if(a) for(j=0;j<n;j=j+1) begin write_byte(data[8*(7-j)+:8],a); acks=acks+a; end
      stop_cond; wait_clk(8);
    end
  endtask
  // ---- UART sender: 20-clock bits, LSB first, 1 stop bit + 0-3 idle bits ----
  reg i2c_busy=0, u_busy=0, uart=0; reg [7:0] u_ref[0:255]; integer u_sent=0, u_seed=7;
  task u_send(input [7:0] v); integer j; begin
    rx_pin=0; repeat(20) @(posedge clk); for(j=0;j<8;j=j+1) begin rx_pin=v[j]; repeat(20) @(posedge clk); end
    rx_pin=1; repeat(20+20*($random(u_seed)&3)) @(posedge clk); end endtask
  initial begin
    wait(i2c_busy); if(uart) begin
      u_busy=1; while(i2c_busy && u_sent<256) begin u_ref[u_sent]=$random(u_seed); u_send(u_ref[u_sent]); u_sent=u_sent+1; end
      u_busy=0; end
  end
  integer acks, base; reg [8*256-1:0] file;
  initial begin
    if(!$value$plusargs("CFG=%s",file)) begin $display("FAIL: no +CFG"); $finish(1); end
    $readmemh(file,mem);
    for(i=0;i<WORDS;i=i+1) cfg[32*i+:32]=mem[i];
    uart=$test$plusargs("UART");
    if(!$value$plusargs("HALF=%d",HALF)) HALF=40;
    if(!$value$plusargs("SETUP=%d",SETUP)) SETUP=10;
    if(!$value$plusargs("HOLD=%d",HOLD)) HOLD=10;
    wait_clk(3); rst_n=1; wait(ready); wait_clk(2);
    run=1; i2c_busy=1; wait_clk(HALF);
    write(8'ha0,2,{8'h11,8'h22,48'd0},acks);
    if(acks!=0 || npushed!=0) begin $display("FAIL: another address: %0d ACKs, %0d stored",acks,npushed);fails=fails+1;end
    write(8'h90,4,{8'h12,8'ha5,8'h00,8'hff,32'd0},acks);
    if(acks!=5) begin $display("FAIL: %0d of 5 ACKs",acks);fails=fails+1;end
    if(npushed!=4) begin $display("FAIL: %0d bytes stored",npushed);fails=fails+1;end
    else if({pushed[0],pushed[1],pushed[2],pushed[3]}!==32'h12a500ff) begin $display("FAIL: stored %h %h %h %h",pushed[0],pushed[1],pushed[2],pushed[3]);fails=fails+1;end
    base=npushed; write(8'h90,1,{8'h90,56'd0},acks);
    if(acks!=2 || npushed!=base+1 || pushed[base]!==8'h90) begin $display("FAIL: second transaction (%0d ACKs, %0d stored)",acks,npushed-base);fails=fails+1;end
    write(8'h22,1,{8'h33,56'd0},acks);
    if(acks!=0 || npushed!=base+1) begin $display("FAIL: third transaction (%0d ACKs)",acks);fails=fails+1;end
    i2c_busy=0; wait(!u_busy); wait_clk(40);
    if(uart) begin
      if(u_n!=u_sent) begin $display("FAIL: UART %0d of %0d bytes",u_n,u_sent);fails=fails+1;end
      else for(i=0;i<u_n;i=i+1) if(u_got[i]!==u_ref[i]) begin $display("FAIL: UART byte %0d = %h want %h",i,u_got[i],u_ref[i]);fails=fails+1;i=u_n;end
    end
    if(fails==0) $display("PASS mesh I2C%s HALF=%0d SETUP=%0d HOLD=%0d (%0d UART bytes)",uart ? " + UART" : "",HALF,SETUP,HOLD,u_sent);
    else $display("FAILED mesh HALF=%0d SETUP=%0d HOLD=%0d (%0d)",HALF,SETUP,HOLD,fails);
    $finish(fails!=0);
  end
  initial begin #20000000; $display("FAIL: timeout"); $finish(1); end
endmodule
`default_nettype wire
