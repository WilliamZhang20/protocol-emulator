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
// Plusargs: +HALF +SETUP +HOLD (clocks), as the sequencer prototype's test.
module slice_i2c_tb;
  reg clk=0; always #1 clk=!clk;
  reg rst_n=0, run=0;
  reg scl_m=1, sda_m=1;
  wire [1:0] io_sinks;                 // cell 1: {SDA value, SDA enable}
  wire sda=sda_m && !(io_sinks[0] && !io_sinks[1]);
  wire scl=scl_m;
  wire [7:0] pins={6'b0,sda,scl};
  // ---- I/O tiles ----
  function [9:0] O(input qpol, input qen, input [2:0] qpin, input [1:0] mode, input [2:0] pin);
    O={qpol,qen,qpin,mode,pin};
  endfunction
  wire [3:0] ioa, iob;
  io_tile tile_a(clk,run,pins,{O(0,1,0,2,1),O(0,0,0,0,1),O(0,0,0,2,0),O(0,0,0,1,0)},ioa); // START, SDA, SCL fall, SCL rise
  io_tile tile_b(clk,run,pins,{30'b0,O(0,1,0,1,1)},iob);                                    // STOP
  // ---- mesh strip ----
  wire [3:0] e0,w1,e1,w2;              // e0: cell0->cell1, w1: cell1->cell0, e1: cell1->cell2, w2: cell2->cell1
  wire [3:0] z=4'b0; wire [3:0] nc0n,nc0s,nc0w,nc1n,nc1s,nc2n,nc2s,nc2e;
  // Track cfg per context: {east, west, south, north}, 3 bits per track.
  function [47:0] T(input [11:0] east, input [11:0] west); T={east,west,24'b0}; endfunction
  function [11:0] TR(input [2:0] t3, input [2:0] t2, input [2:0] t1, input [2:0] t0); TR={t3,t2,t1,t0}; endfunction
  function [13:0] X(input [1:0] bn, input [4:0] be, input [1:0] an, input [4:0] ae); X={bn,be,an,ae}; endfunction
  localparam L0=2, L1=3, L2=4, L3=5, W0=14, W1=15, W2=16, W3=17, E0=18, ONE=1, ZERO=0;
  // cell 0: east t3 = local 0 (STOP), every context.
  wire [1:0] c0;
  ctx_switch #(.NSINK(1)) sw0(clk,run,z,z,z,w1,iob,
    {4{T(TR(3'd1,0,0,0),12'b0)}}, 20'b0, 56'b0, nc0n,nc0s,nc0w,e0,, c0);
  // cell 1.
  localparam [47:0] T1_NORM=T(TR(3'd5,3'd4,3'd3,3'd1),12'b0);  // east: t3 straight (STOP), t2 START, t1 SDA, t0 SCL rise
  localparam [47:0] T1_DRIVE=T(TR(3'd5,3'd2,3'd3,3'd1),12'b0); // DRIVE: t2 carries SCL fall (ACK-END)
  wire [1:0] c1;
  ctx_switch #(.NSINK(2)) sw1(clk,run,z,z,e0,w2,ioa,
    {T1_NORM,T1_DRIVE,T1_NORM,T1_NORM},
    {5'd0,5'd0, 5'd0,5'(ONE), 5'd0,5'd0, 5'd0,5'd0},          // sinks {value, enable}, contexts 3..0 (MSB first); DRIVE (2): enable = 1
    {14'b0, X(0,5'(L1),0,5'(L1)), X(1,5'(L1),2,5'(L1)), X(1,5'(E0),1,5'(E0))}, // 0 RELEASE: ACK-GO->1; 1 WAIT: SCL fall->2; 2 DRIVE: SCL fall->0
    nc1n,nc1s,w1,e1, io_sinks, c1);
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
  initial begin
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
    @(negedge clk); cfg_we=0; if(!ok) begin $display("FAIL: word network configuration refused");fails=fails+1;end
    run=1; wait_clk(HALF);
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
    if(fails==0) $display("PASS slice I2C HALF=%0d SETUP=%0d HOLD=%0d",HALF,SETUP,HOLD);
    else $display("FAILED slice I2C HALF=%0d SETUP=%0d HOLD=%0d (%0d)",HALF,SETUP,HOLD,fails);
    $finish(fails!=0);
  end
  initial begin #5000000; $display("FAIL: timeout"); $finish(1); end
endmodule
`default_nettype wire
