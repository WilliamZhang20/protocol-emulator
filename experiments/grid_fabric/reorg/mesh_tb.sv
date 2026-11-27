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
// Plusargs: +CFG +HALF +SETUP +HOLD (clocks) +UART; +TX instead runs a
// transmit test: bytes through the reader port, decoded as 8N1 at 20
// clocks per bit on pad 3 (push-pull); +CRCTX a burst with a CRC-16 tail
// on pads 3/5 (a pair, 5 inverted) clocked by pad 4, the CRC recomputed
// here.
module mesh_tb #(parameter ROWS=3, COLS=5, WORD_PORT=6,
  parameter [2*ROWS*COLS-1:0] KINDS=30'd287029521,
  parameter [ROWS*COLS-1:0] CTX4=15'd10570,
  parameter [ROWS*COLS-1:0] CNT=0,
  parameter [ROWS*COLS-1:0] LOGIC=0);
  localparam N=ROWS*COLS, CFG_BITS=N*512+128, WORDS=(CFG_BITS+31)/32;
  reg clk=0; always #1 clk=!clk;
  reg rst_n=0, run=0;
  reg [31:0] mem[0:WORDS-1];
  reg [CFG_BITS-1:0] cfg;
  reg scl_m=1, sda_m=1, rx_pin=1;
  wire [7:0] pad_oe, pad_out;
  wire [7:0] ext={5'b0,rx_pin,sda_m,scl_m};
  wire [7:0] pins=(pad_oe & pad_out) | (~pad_oe & ext);    // a driven pad wins
  wire scl=pins[0], sda=pins[1];
  wire rd_ready; reg [7:0] rdq[0:63]; integer rdn=0, rdi=0;
  wire rd_valid=rdi<rdn;
  always @(posedge clk) if(rd_valid && rd_ready) rdi<=rdi+1;
  wire ready, wr_valid; wire [15:0] wr_data;
  wire [N-1:0] host_valid; wire [8*N-1:0] host_byte;
  wire [4*N-1:0] seen;
  mesh #(.ROWS(ROWS),.COLS(COLS),.WORD_PORT(WORD_PORT),.KINDS(KINDS),.CTX4(CTX4),.CNT(CNT),.LOGIC(LOGIC)) dut(
    clk,rst_n,run,4'b0,seen,1'b0,1'b0,4'b0,3'b0,16'b0,cfg,pins,pad_oe,pad_out,ready,{8'd0,rdq[rdi]},rd_valid,rd_ready,wr_data,wr_valid,1'b1,host_valid,host_byte);
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
  task crc_tx_test;
    reg [15:0] crc, tailw; reg [7:0] w; integer j, b, n, nbits, seed, bad_pair; reg prev, d;
    reg bits[0:1023];
    begin
      seed=5; n=6; nbits=0; bad_pair=0;
      for(j=0;j<n;j=j+1) rdq[j]=$random(seed);
      run=1; wait_clk(4); rdn=n;
      // Bit 0 is on the line from the start of the frame until the first
      // clock edge; each later bit follows an edge.
      wait(pad_oe[3]); prev=pins[4]; repeat(4) @(posedge clk); bits[0]=pins[3]; nbits=1;
      while(pad_oe[3]) begin
        @(posedge clk);
        if(pad_oe[3] && (pins[3]===pins[5])) bad_pair=bad_pair+1;
        if(pad_oe[3] && pins[4]!==prev) begin
          prev=pins[4]; repeat(3) @(posedge clk);
          if(pad_oe[3]) begin bits[nbits]=pins[3]; nbits=nbits+1; end
        end
      end
      if(bad_pair) begin $display("FAIL: pair not complementary on %0d clocks",bad_pair);fails=fails+1;end
      crc=16'hffff;
      for(j=0;j<n;j=j+1) for(b=0;b<8;b=b+1) begin d=rdq[j][b]; crc={crc[14:0],1'b0}^((crc[15]^d) ? 16'h8005 : 16'h0); end
      tailw=~crc;
      $display("received %0d bits (want %0d)",nbits,8*n+16);
      if(nbits!=8*n+16) begin $display("FAIL: bit count");fails=fails+1;end
      else begin
        for(j=0;j<n;j=j+1) begin for(b=0;b<8;b=b+1) w[b]=bits[8*j+b]; if(w!==rdq[j]) begin $display("FAIL: word %0d %h want %h",j,w,rdq[j]);fails=fails+1;end end
        for(b=0;b<16;b=b+1) if(bits[8*n+b]!==tailw[15-b]) begin $display("FAIL: tail bit %0d",b);fails=fails+1;b=16;end
      end
      if(fails==0) $display("PASS mesh CRC tail: %0d words from the reader + CRC-16 from the linked CRC cell, complementary pad pair",n);
      else $display("FAILED mesh CRC tail (%0d)",fails);
      $finish(fails!=0);
    end
  endtask
  // ---- transmit test: pad 3 decoded as 8N1 at 20 clocks per bit ----
  task tx_test;
    reg [7:0] got; integer j, b, n, t0, t1, seed;
    begin
      seed=3; n=12;
      for(j=0;j<n;j=j+1) rdq[j]=$random(seed);
      wait_clk(5); if(pad_oe[3]!==0) begin $display("FAIL: tx pad driven before run");fails=fails+1;end
      run=1; wait_clk(4);
      if(!(pad_oe[3] && pins[3])) begin $display("FAIL: tx not idle high");fails=fails+1;end
      rdn=n;
      for(j=0;j<n;j=j+1) begin
        @(negedge pins[3]); if(j==0) t0=$time;
        repeat(10) @(posedge clk); if(pins[3]!==0) begin $display("FAIL: start bit %0d",j);fails=fails+1;end
        for(b=0;b<8;b=b+1) begin repeat(20) @(posedge clk); got[b]=pins[3]; end
        repeat(20) @(posedge clk); if(pins[3]!==1) begin $display("FAIL: stop bit %0d",j);fails=fails+1;end
        if(got!==rdq[j]) begin $display("FAIL: byte %0d sent %h want %h",j,got,rdq[j]);fails=fails+1;end
      end
      t1=$time; wait_clk(100);
      if(rdi!=n || pins[3]!==1) begin $display("FAIL: %0d of %0d read, line %b",rdi,n,pins[3]);fails=fails+1;end
      if(fails==0) $display("PASS mesh UART TX: %0d bytes from the reader, 8N1 at 20 clocks per bit, %0d clocks",n,(t1-t0)/2);
      else $display("FAILED mesh UART TX (%0d)",fails);
      $finish(fails!=0);
    end
  endtask
  initial begin
    if(!$value$plusargs("CFG=%s",file)) begin $display("FAIL: no +CFG"); $finish(1); end
    $readmemh(file,mem);
    for(i=0;i<WORDS;i=i+1) cfg[32*i+:32]=mem[i];
    uart=$test$plusargs("UART");
    if(!$value$plusargs("HALF=%d",HALF)) HALF=40;
    if(!$value$plusargs("SETUP=%d",SETUP)) SETUP=10;
    if(!$value$plusargs("HOLD=%d",HOLD)) HOLD=10;
    wait_clk(3); rst_n=1; wait(ready); wait_clk(2);
    if($test$plusargs("TX")) tx_test;
    if($test$plusargs("CRCTX")) crc_tx_test;
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
