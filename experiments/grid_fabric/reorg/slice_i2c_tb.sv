`timescale 1ns/1ps
`default_nettype none
// I2C target slice (FABRIC_REORG.md step 3c, promotion criterion 1): control
// in the interconnect. A 1 x 3 strip of the mesh, west to east:
//   cell 0  I/O tile B (STOP)            static switch
//   cell 1  I/O tile A (SCL rise, SCL fall, SDA level, START) + the SDA pad
//           sinks; contexted switch: RELEASE -ACK-GO-> WAIT -SCL fall->
//           DRIVE -SCL fall-> RELEASE; DRIVE drives SDA low and puts
//           "SCL fall" (ACK-END) on the START track
//   cell 2  the real fabric_shifter (8-bit receive frames on SCL rise) and
//           the word network (rx -> gate -> writer; compare taps rx);
//           contexted switch: IDLE -START-> ADDR -match-> ON / -mismatch->
//           OFF; ON, OFF -STOP-> IDLE. ADDR routes the match pulse and ON
//           the word pulse west as ACK-GO; IDLE and ON start the shifter
//           from the START track; ON opens the gate.
// No sequencer, controller or LUT: every decision is a routing context.
//
// Concurrency (promotion criterion 2): a UART receive in column 1 below the
// strip, on its own tiles,
//   cell 4  grid_timer (start <- RX fall, stop <- shifter stop; bit 20 clk)
//   cell 7  a second fabric_shifter (the shipped uart-rx-plain frame word)
// takes the RX level and RX fall from I/O tile B in cell 0 *through* cell
// 1's contexted switch (west t0/t1 turn south), so every I2C context change
// happens under a live UART route. The compiler's invariant: a selector
// used by another design is identical in every context of that switch.
// Plusargs: +HALF +SETUP +HOLD (clocks), as the sequencer prototype's test;
// +UART sends a byte stream on the RX pin throughout the I2C transactions;
// +BAD breaks the invariant (DRIVE drops the RX level route), which must
// corrupt the UART and nothing else.
module slice_i2c_tb;
  reg clk=0; always #1 clk=!clk;
  reg rst_n=0, run=0;
  reg scl_m=1, sda_m=1, rx_pin=1, bad=0;
  wire [1:0] io_sinks;                 // cell 1: {SDA value, SDA enable}
  wire sda=sda_m && !(io_sinks[0] && !io_sinks[1]);
  wire scl=scl_m;
  wire [7:0] pins={5'b0,rx_pin,sda,scl};
  // ---- I/O tiles ----
  function [9:0] O(input qpol, input qen, input [2:0] qpin, input [1:0] mode, input [2:0] pin);
    O={qpol,qen,qpin,mode,pin};
  endfunction
  wire [3:0] ioa, iob;
  io_tile tile_a(clk,run,pins,{O(0,1,0,2,1),O(0,0,0,0,1),O(0,0,0,2,0),O(0,0,0,1,0)},ioa); // START, SDA, SCL fall, SCL rise
  io_tile tile_b(clk,run,pins,{10'b0,O(0,0,0,2,2),O(0,0,0,0,2),O(0,1,0,1,1)},iob);           // RX fall, RX level, STOP
  // ---- mesh strip ----
  wire [3:0] e0,w1,e1,w2;              // e0: cell0->cell1, w1: cell1->cell0, e1: cell1->cell2, w2: cell2->cell1
  wire [3:0] s1,s4,n7;                 // s1: cell1->cell4, s4: cell4->cell7, n7: cell7->cell4
  wire [3:0] z=4'b0; wire [3:0] nc0n,nc0s,nc0w,nc1n,nc2n,nc2s,nc2e,nc4n,nc4w,nc4e,nc7s,nc7w,nc7e;
  // Track cfg per context: {east, west, south, north}, 3 bits per track.
  function [47:0] T(input [11:0] east, input [11:0] west); T={east,west,24'b0}; endfunction
  function [47:0] T4(input [11:0] east, input [11:0] west, input [11:0] south, input [11:0] north); T4={east,west,south,north}; endfunction
  function [11:0] TR(input [2:0] t3, input [2:0] t2, input [2:0] t1, input [2:0] t0); TR={t3,t2,t1,t0}; endfunction
  function [13:0] X(input [1:0] bn, input [4:0] be, input [1:0] an, input [4:0] ae); X={bn,be,an,ae}; endfunction
  localparam L0=2, L1=3, L2=4, L3=5, W0=14, W1=15, W2=16, W3=17, E0=18, ONE=1, ZERO=0;
  // cell 0: east t3 = local 0 (STOP), t1 local 2 (RX fall), t0 local 1 (RX level), every context.
  wire [1:0] c0;
  ctx_switch #(.NSINK(1)) sw0(clk,run,z,z,z,w1,iob,
    {4{T(TR(3'd1,0,3'd3,3'd2),12'b0)}}, 20'b0, 56'b0, nc0n,nc0s,nc0w,e0,, c0);
  // cell 1.
  // East: t3 straight (STOP), t2 START, t1 SDA, t0 SCL rise. South (the
  // UART's route, every context): t1 and t0 turn from the west (6).
  localparam [47:0] T1_NORM=T4(TR(3'd5,3'd4,3'd3,3'd1),12'b0,TR(0,0,3'd6,3'd6),12'b0);
  localparam [47:0] T1_DRIVE=T4(TR(3'd5,3'd2,3'd3,3'd1),12'b0,TR(0,0,3'd6,3'd6),12'b0); // DRIVE: t2 carries SCL fall (ACK-END)
  wire [47:0] t1_drive=bad ? T4(TR(3'd5,3'd2,3'd3,3'd1),12'b0,TR(0,0,3'd6,3'd0),12'b0) : T1_DRIVE; // +BAD: DRIVE drops south t0
  wire [1:0] c1;
  ctx_switch #(.NSINK(2)) sw1(clk,run,z,z,e0,w2,ioa,
    {T1_NORM,t1_drive,T1_NORM,T1_NORM},
    {5'd0,5'd0, 5'd0,5'(ONE), 5'd0,5'd0, 5'd0,5'd0},          // sinks {value, enable}, contexts 3..0 (MSB first); DRIVE (2): enable = 1
    {14'b0, X(0,5'(L1),0,5'(L1)), X(1,5'(L1),2,5'(L1)), X(1,5'(E0),1,5'(E0))}, // 0 RELEASE: ACK-GO->1; 1 WAIT: SCL fall->2; 2 DRIVE: SCL fall->0
    nc1n,s1,w1,e1, io_sinks, c1);
  // cell 2: shifter + word network. Local outputs: 0 word, 1 match, 2 mismatch.
  wire c_word, c_stop, t_match, t_mismatch;
  wire [3:0] l2={1'b0,t_mismatch,t_match,c_word};
  wire [4:0] sh_sinks;                // {gate, abort, in, shift, start}
  localparam [47:0] T2_IDLE=T(12'b0,12'b0), T2_ADDR=T(12'b0,TR(0,0,0,3'd2)), T2_ON=T(12'b0,TR(0,0,0,3'd1));
  wire [1:0] c2;
  ctx_switch #(.NSINK(5)) sw2(clk,run,z,z,e1,z,l2,
    {T2_IDLE,T2_ON,T2_ADDR,T2_IDLE},                           // contexts 3 OFF, 2 ON, 1 ADDR, 0 IDLE
    {{5'd0,5'(W3),5'(W1),5'(W0),5'd0},                         // OFF: no start
     {5'(ONE),5'(W3),5'(W1),5'(W0),5'(W2)},                    // ON: gate open, start on the START track (ACK-END)
     {5'd0,5'(W3),5'(W1),5'(W0),5'd0},                         // ADDR: running
     {5'd0,5'(W3),5'(W1),5'(W0),5'(W2)}},                      // IDLE: start on START
    {X(0,5'(W3),0,5'(W3)), X(0,5'(W3),0,5'(W3)), X(3,5'(L2),2,5'(L1)), X(1,5'(W2),1,5'(W2))},
    nc2n,nc2s,w2,nc2e, sh_sinks, c2);
  // The real shifter: lines 1 start, 2 shift/sample, 3 abort; level 33 SDA.
  wire [63:0] lines={30'b0,sh_sinks[2],1'b0,28'b0,sh_sinks[3],sh_sinks[1],sh_sinks[0],1'b0};
  reg cfg_we=0; reg [2:0] cfg_addr=0; reg [15:0] cfg_data=0;
  wire rx_req, rx_ready; wire [7:0] rx_byte;
  wire unused_pulls, unused_txr, unused_eop, unused_err, unused_out, unused_active, unused_ab, unused_bit, unused_em;
  wire [15:0] unused_rxd, unused_st;
  fabric_shifter sh(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we(cfg_we),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
    .cfg_bank(2'b11),.ctx_next(1'b0),.lines(lines),.pulls(unused_pulls),.tx_request(unused_txr),.tx_grant(1'b0),
    .tx_data(8'd0),.tx_eop(1'b0),.tx_err(1'b0),.rx_request(rx_req),.rx_grant(rx_req && rx_ready),.crc_in(1'b0),
    .rx_byte(rx_byte),.rx_eop(unused_eop),.rx_err(unused_err),.out(unused_out),.active(unused_active),
    .word_pulse(c_word),.stop_pulse(c_stop),.rx_data(unused_rxd),.status(unused_st),
    .crc_absorb(unused_ab),.crc_bit(unused_bit),.crc_emit(unused_em));
  // Word network: gate <- rx, writer <- gate; compare taps rx (source 2).
  wire [15:0] wr_data; wire wr_valid; wire ok, unused_match;
  wire [15:0] unused_tx; wire unused_txv, unused_rd, unused_st_r, unused_cap;
  wnet words(clk,rst_n,{4'd0,4'd0,4'd0,4'd2,4'd0,4'd0,4'd0,4'd7},  // sinks: writer<-gate(7), gate<-rx(2)
    8'd0,8'd0,8'd0,8'd0,8'd0,16'h0090,16'h00ff,sh_sinks[4],unused_match,1'b0,4'd2,t_match,t_mismatch,
    16'd0,1'b0,unused_rd, {8'd0,rx_byte},rx_req,rx_ready, 16'd0,1'b0,unused_st_r, 16'd0,1'b0,unused_cap,
    wr_data,wr_valid,1'b1, unused_tx,unused_txv,1'b1, ok);
  reg [7:0] pushed[0:31]; integer npushed=0;
  always @(posedge clk) if(wr_valid) begin pushed[npushed]<=wr_data[7:0];npushed<=npushed+1;end
  // ---- UART receive column: cell 4 timer, cell 7 shifter (static switches) ----
  localparam N0=6, N1=7, N2=8, S0=10;
  wire u_tick, u_stop, u_word; wire [2:0] t_sinks; wire [2:0] u_sinks; // timer {aux, stop, start}; shifter {in, shift, start}
  wire [1:0] c4, c7;
  ctx_switch #(.NSINK(3)) sw4(clk,run,s1,n7,z,z,{3'b0,u_tick},
    {4{T4(12'b0,12'b0,TR(0,3'd1,3'd5,3'd5),12'b0)}},           // south: t2 tick, t1/t0 straight (RX fall, RX level)
    {4{5'd0,5'(S0),5'(N1)}}, 56'b0, nc4n,s4,nc4w,nc4e, t_sinks, c4);
  ctx_switch #(.NSINK(3)) sw7(clk,run,s4,z,z,z,{3'b0,u_stop},
    {4{T4(12'b0,12'b0,12'b0,TR(0,0,0,3'd1))}},                 // north t0: shifter stop -> timer
    {4{5'(N0),5'(N2),5'(N1)}}, 56'b0, n7,nc7s,nc7w,nc7e, u_sinks, c7);
  reg t_cfg=0;
  wire u_running, u_configured, u_level, u_rise, u_fall; wire [15:0] u_cap;
  grid_timer timer(clk,rst_n,run,t_cfg,16'd8,16'd20,1'b0,16'd0,16'd0,16'd0,16'd0,
    t_sinks[0],t_sinks[1],t_sinks[2],u_tick,u_running,u_configured,u_level,u_rise,u_fall,u_cap);
  wire [63:0] u_lines={30'b0,u_sinks[2],1'b0,29'b0,u_sinks[1],u_sinks[0],1'b0};
  reg u_cfg_we=0;
  wire u_req; wire [7:0] u_byte;
  wire [8:0] u_nc; wire [15:0] u_rxd, u_st;
  fabric_shifter ush(.clk(clk),.rst_n(rst_n),.enable(run),.cfg_we(u_cfg_we),.cfg_addr(cfg_addr),.cfg_data(cfg_data),
    .cfg_bank(2'b11),.ctx_next(1'b0),.lines(u_lines),.pulls(u_nc[0]),.tx_request(u_nc[1]),.tx_grant(1'b0),
    .tx_data(8'd0),.tx_eop(1'b0),.tx_err(1'b0),.rx_request(u_req),.rx_grant(u_req),.crc_in(1'b0),
    .rx_byte(u_byte),.rx_eop(u_nc[2]),.rx_err(u_nc[3]),.out(u_nc[4]),.active(u_nc[5]),
    .word_pulse(u_word),.stop_pulse(u_stop),.rx_data(u_rxd),.status(u_st),
    .crc_absorb(u_nc[6]),.crc_bit(u_nc[7]),.crc_emit(u_nc[8]));
  reg [7:0] u_got[0:255]; integer u_n=0;
  always @(posedge clk) if(u_req) begin u_got[u_n]<=u_byte;u_n<=u_n+1;end
  // DRIVE clocks seen while a UART frame is in flight (the overlap tested).
  integer overlap=0;
  always @(posedge clk) if(c1==2 && u_running) overlap<=overlap+1;
  // ---- controller model ----
  integer HALF=40, SETUP=10, HOLD=10, fails=0, i;
  task wait_clk(input integer n); repeat(n) @(posedge clk); endtask
  task clock_bit(input b, output seen);
    begin wait_clk(HOLD); sda_m=b; wait_clk(SETUP); scl_m=1; wait_clk(HALF/2); seen=sda; wait_clk(HALF-HALF/2); scl_m=0; end
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
  task write(input [7:0] addr, input integer n, input [8*8-1:0] data, output integer acks);
    reg a; integer k;
    begin
      start_cond; write_byte(addr,a); acks=a;
      if(a) for(k=0;k<n;k=k+1) begin write_byte(data[8*(7-k)+:8],a); acks=acks+a; end
      stop_cond; wait_clk(8);
    end
  endtask
  integer acks, base;
  // UART sender: 20-clock bits, LSB first, one stop bit and 0-3 idle bits,
  // pseudo-random bytes, for as long as the I2C transactions run.
  reg i2c_busy=0, u_busy=0, uart=0, u_bad=0; reg [7:0] u_ref[0:255]; integer u_sent=0, u_seed=7, i2c_fails=0;
  task u_send(input [7:0] v); integer k; begin
    // (its own waits: wait_clk is static and also used by the I2C process)
    rx_pin=0; repeat(20) @(posedge clk); for(k=0;k<8;k=k+1) begin rx_pin=v[k]; repeat(20) @(posedge clk); end
    rx_pin=1; repeat(20+20*($random(u_seed)&3)) @(posedge clk); end endtask
  initial begin
    wait(i2c_busy); if(uart) begin
      u_busy=1; while(i2c_busy && u_sent<256) begin u_ref[u_sent]=$random(u_seed); u_send(u_ref[u_sent]); u_sent=u_sent+1; end
      u_busy=0; end
  end
  initial begin
    uart=$test$plusargs("UART"); bad=$test$plusargs("BAD");
    if(!$value$plusargs("HALF=%d",HALF)) HALF=40;
    if(!$value$plusargs("SETUP=%d",SETUP)) SETUP=10;
    if(!$value$plusargs("HOLD=%d",HOLD)) HOLD=10;
    wait_clk(3); rst_n=1;
    // Shifter: frame 8 bits MSB first (0x1007), shift = sample = line 2,
    // start line 1, input level 33 (1), auto push; abort line 3.
    @(negedge clk); cfg_we=1; cfg_addr=1; cfg_data=16'h1007;
    @(negedge clk); cfg_addr=2; cfg_data=16'd2 | (16'd2<<6);
    @(negedge clk); cfg_addr=3; cfg_data=16'd1 | (16'd1<<6) | (16'd1<<12);
    @(negedge clk); cfg_addr=4; cfg_data=16'd3<<7;
    // UART shifter: the shipped uart-rx-plain frame word (0x8297: 8 data
    // bits LSB first, a 0 start and a 1 stop bit, idle 1), shift = sample
    // = line 2, start line 1, input level 33, auto push. Timer: first 8,
    // period 20 (uart-rx-plain's timer words).
    @(negedge clk); cfg_we=0; u_cfg_we=1; cfg_addr=1; cfg_data=16'h8297;
    @(negedge clk); cfg_addr=2; cfg_data=16'd2 | (16'd2<<6);
    @(negedge clk); cfg_addr=3; cfg_data=16'd1 | (16'd1<<6) | (16'd1<<12);
    @(negedge clk); cfg_addr=4; cfg_data=0;
    @(negedge clk); u_cfg_we=0; t_cfg=1;
    @(negedge clk); t_cfg=0; if(!ok) begin $display("FAIL: word network configuration refused");fails=fails+1;end
    run=1; i2c_busy=1; wait_clk(HALF);
    // 1. Another address (0x50): NAK, nothing stored, back to IDLE.
    write(8'ha0,2,{8'h11,8'h22,48'd0},acks);
    if(acks!=0) begin $display("FAIL: 0x50 ACKed");fails=fails+1;end
    if(npushed!=0 || c2!=0 || c1!=0) begin $display("FAIL: after NAK: %0d stored, contexts %0d/%0d",npushed,c2,c1);fails=fails+1;end
    // 2. 0x48 with four bytes: five ACKs, four bytes stored, address dropped.
    write(8'h90,4,{8'h12,8'ha5,8'h00,8'hff,32'd0},acks);
    if(acks!=5) begin $display("FAIL: %0d of 5 ACKs",acks);fails=fails+1;end
    if(npushed!=4) begin $display("FAIL: %0d bytes stored",npushed);fails=fails+1;end
    else if({pushed[0],pushed[1],pushed[2],pushed[3]}!==32'h12a500ff) begin $display("FAIL: stored %h %h %h %h",pushed[0],pushed[1],pushed[2],pushed[3]);fails=fails+1;end
    if(c2!=0 || c1!=0) begin $display("FAIL: contexts after STOP %0d/%0d",c2,c1);fails=fails+1;end
    // 3. Back to back: another 0x48 write (one byte 0x90, equal to the
    //    address: a data byte, not an address), then a write elsewhere.
    base=npushed; write(8'h90,1,{8'h90,56'd0},acks);
    if(acks!=2 || npushed!=base+1 || pushed[base]!==8'h90) begin $display("FAIL: second transaction (%0d ACKs, %0d stored)",acks,npushed-base);fails=fails+1;end
    write(8'h22,1,{8'h33,56'd0},acks);
    if(acks!=0 || npushed!=base+1) begin $display("FAIL: third transaction (%0d ACKs)",acks);fails=fails+1;end
    i2c_fails=fails; i2c_busy=0; wait(!u_busy); wait_clk(40);
    if(uart) begin
      if(u_n!=u_sent) begin $display("FAIL: UART %0d of %0d bytes received",u_n,u_sent);fails=fails+1;u_bad=1;end
      else for(i=0;i<u_n;i=i+1) if(u_got[i]!==u_ref[i]) begin
        if(!u_bad) $display("FAIL: UART byte %0d = %h want %h",i,u_got[i],u_ref[i]); fails=fails+1; u_bad=1; end
      if(overlap==0) begin $display("FAIL: no DRIVE context during a UART frame (nothing tested)");fails=fails+1;end
    end
    if(fails==0 && uart) $display("PASS slice I2C + UART HALF=%0d SETUP=%0d HOLD=%0d (%0d UART bytes, %0d DRIVE clocks under a frame)",HALF,SETUP,HOLD,u_sent,overlap);
    else if(fails==0) $display("PASS slice I2C HALF=%0d SETUP=%0d HOLD=%0d",HALF,SETUP,HOLD);
    else if(i2c_fails==0 && u_bad) $display("FAILED slice I2C + UART HALF=%0d SETUP=%0d HOLD=%0d: UART only, I2C intact",HALF,SETUP,HOLD);
    else $display("FAILED slice I2C HALF=%0d SETUP=%0d HOLD=%0d (%0d)",HALF,SETUP,HOLD,fails);
    $finish(fails!=0);
  end
  initial begin #20000000; $display("FAIL: timeout"); $finish(1); end
endmodule
`default_nettype wire
