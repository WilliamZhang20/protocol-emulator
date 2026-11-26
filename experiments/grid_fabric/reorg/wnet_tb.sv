`timescale 1ns/1ps
`default_nettype none
// Word network prototype (wnet.v): each stage assigned independently,
// under random backpressure on every endpoint. Configurations:
//  1 SLIP tx    reader -> escape -> tx
//  2 HDLC tx    the same stage, other constants
//  3 chain      reader -> escape -> compare -> tx (stages in sequence)
//  4 I2C rx     rx -> compare -> gate -> writer (gate bit from the "mesh")
//  5 tagged rx  rx -> interleave.a, status -> interleave.b, interleave -> writer
//  6 capture    capture -> split -> writer
//  7 two at once: SLIP tx (1) and capture split (6) together
//  8 refused    a source outside a sink's reach list; one source to two sinks
module wnet_tb;
  reg clk=0; always #1 clk=!clk;
  reg rst_n=0;
  reg [31:0] sel=0;
  reg [7:0] m0=8'hc0, m1=8'hdb, eb=8'hdb, r0=8'hdc, r1=8'hdd;
  reg [15:0] cv=16'h0090, cm=16'h00ff; reg gate=0, msb=0;
  wire match, ok;
  // Sources driven from queues; sinks captured into arrays.
  reg [15:0] rdq[0:63], rxq[0:63], stq[0:63], cpq[0:63]; integer rdn=0, rxn=0, stn=0, cpn=0, rdi=0, rxi=0, sti=0, cpi=0;
  reg [15:0] wr_got[0:127], tx_got[0:127]; integer wrn=0, txn=0;
  reg wr_rdy=0, tx_rdy=0;
  wire rd_ready, rx_ready, st_ready, cap_ready, wr_valid, tx_valid; wire [15:0] wr_data, tx_data;
  wire rd_valid=rdi<rdn, rx_valid=rxi<rxn, st_valid=sti<stn, cap_valid=cpi<cpn;
  wire tm, tmm;
  wnet dut(clk,rst_n,sel,m0,m1,eb,r0,r1,cv,cm,gate,match,msb,4'd0,tm,tmm,
    rdq[rdi],rd_valid,rd_ready, rxq[rxi],rx_valid,rx_ready, stq[sti],st_valid,st_ready, cpq[cpi],cap_valid,cap_ready,
    wr_data,wr_valid,wr_rdy, tx_data,tx_valid,tx_rdy, ok);
  integer seed=1;
  always @(posedge clk) begin
    if(rd_valid && rd_ready) rdi<=rdi+1;
    if(rx_valid && rx_ready) rxi<=rxi+1;
    if(st_valid && st_ready) sti<=sti+1;
    if(cap_valid && cap_ready) cpi<=cpi+1;
    if(wr_valid && wr_rdy) begin wr_got[wrn]<=wr_data;wrn<=wrn+1;end
    if(tx_valid && tx_rdy) begin tx_got[txn]<=tx_data;txn<=txn+1;end
  end
  always @(negedge clk) begin wr_rdy<=($random(seed)&3)!=0; tx_rdy<=($random(seed)&1); end
  integer fails=0, i;
  task reset_all; begin rst_n=0; rdn=0;rxn=0;stn=0;cpn=0;rdi=0;rxi=0;sti=0;cpi=0;wrn=0;txn=0; repeat(2) @(posedge clk); rst_n=1; end endtask
  task run(input integer n); repeat(n) @(posedge clk); endtask
  task check_tx(input integer n, input [8*64-1:0] exp);
    integer k; begin
      if(txn!=n) begin $display("FAIL tx count %0d want %0d",txn,n);fails=fails+1;end
      else for(k=0;k<n;k=k+1) if(tx_got[k]!==exp[8*(63-k)+:8]) begin $display("FAIL tx[%0d]=%h want %h",k,tx_got[k],exp[8*(63-k)+:8]);fails=fails+1;end
    end endtask
  task check_wr(input integer n, input [8*64-1:0] exp);
    integer k; begin
      if(wrn!=n) begin $display("FAIL wr count %0d want %0d",wrn,n);fails=fails+1;end
      else for(k=0;k<n;k=k+1) if(wr_got[k]!==exp[8*(63-k)+:8]) begin $display("FAIL wr[%0d]=%h want %h",k,wr_got[k],exp[8*(63-k)+:8]);fails=fails+1;end
    end endtask
  // sel helper: sink k <- source v
  function [31:0] S(input [31:0] base, input integer k, input [3:0] v); S=base; S[4*k+:4]=v; endfunction
  localparam RD=1, RX=2, ST=3, CAP=4, ESC=5, CMP=6, GATE=7, SPL=8, ILV=9;
  localparam K_WR=0, K_TX=1, K_ESC=2, K_CMP=3, K_GATE=4, K_SPL=5, K_ILA=6, K_ILB=7;
  initial begin
    // 1 SLIP: 01 C0 02 DB 03 -> 01 DB DC 02 DB DD 03
    reset_all; sel=S(S(0,K_ESC,RD),K_TX,ESC);
    rdq[0]=8'h01;rdq[1]=8'hc0;rdq[2]=8'h02;rdq[3]=8'hdb;rdq[4]=8'h03; rdn=5; run(200);
    if(!ok) begin $display("FAIL slip config refused");fails=fails+1;end
    check_tx(7,{8'h01,8'hdb,8'hdc,8'h02,8'hdb,8'hdd,8'h03,456'd0});
    // 2 HDLC: 7E->7D 5E, 7D->7D 5D
    reset_all; m0=8'h7e; m1=8'h7d; eb=8'h7d; r0=8'h5e; r1=8'h5d;
    rdq[0]=8'h7e;rdq[1]=8'h41;rdq[2]=8'h7d; rdn=3; run(200);
    check_tx(5,{8'h7d,8'h5e,8'h41,8'h7d,8'h5d,472'd0});
    // 3 chain: reader -> escape -> compare -> tx (compare passes words on)
    reset_all; m0=8'hc0; m1=8'hdb; eb=8'hdb; r0=8'hdc; r1=8'hdd; sel=S(S(S(0,K_ESC,RD),K_CMP,ESC),K_TX,CMP);
    rdq[0]=8'hc0;rdq[1]=8'h90; rdn=2; run(200);
    if(!ok) begin $display("FAIL chain refused");fails=fails+1;end
    check_tx(3,{8'hdb,8'hdc,8'h90,488'd0});
    if(!match) begin $display("FAIL compare: last word 0x90 not matched");fails=fails+1;end
    // 4 I2C rx: address 0x90 dropped (gate closed), data passed (gate open)
    reset_all; sel=S(S(S(0,K_CMP,RX),K_GATE,CMP),K_WR,GATE); gate=0;
    rxq[0]=8'h90; rxn=1; run(20);
    if(!match) begin $display("FAIL address not matched");fails=fails+1;end
    gate=1; rxq[1]=8'h12; rxq[2]=8'ha5; rxn=3; run(100);
    check_wr(2,{8'h12,8'ha5,496'd0});
    if(match) begin $display("FAIL match held after a data byte");fails=fails+1;end
    // 5 tagged rx: byte then status, repeated
    reset_all; gate=0; sel=S(S(S(0,K_ILA,RX),K_ILB,ST),K_WR,ILV);
    rxq[0]=8'h55; rxq[1]=8'h66; stq[0]=8'h00; stq[1]=8'h40; rxn=2; stn=2; run(200);
    check_wr(4,{8'h55,8'h00,8'h66,8'h40,480'd0});
    // 6 capture split, low byte first
    reset_all; sel=S(S(0,K_SPL,CAP),K_WR,SPL); msb=0;
    cpq[0]=16'h1234; cpq[1]=16'hbeef; cpn=2; run(200);
    check_wr(4,{8'h34,8'h12,8'hef,8'hbe,480'd0});
    // 7 two at once: SLIP tx and capture split
    reset_all; sel=S(S(S(S(0,K_ESC,RD),K_TX,ESC),K_SPL,CAP),K_WR,SPL);
    rdq[0]=8'hc0; rdn=1; cpq[0]=16'habcd; cpn=1; run(200);
    if(!ok) begin $display("FAIL concurrent config refused");fails=fails+1;end
    check_tx(2,{8'hdb,8'hdc,496'd0}); check_wr(2,{8'hcd,8'hab,496'd0});
    // 8 refused: tx <- capture (outside its reach); reader to two sinks.
    // Nothing moves while the configuration is invalid.
    reset_all; sel=S(0,K_TX,CAP); cpq[0]=16'h0001; cpn=1; run(20);
    if(ok || txn!=0 || cpi!=0) begin $display("FAIL out-of-reach source accepted (ok %b)",ok);fails=fails+1;end
    reset_all; sel=S(S(0,K_ESC,RD),K_CMP,RD); rdq[0]=1; rdn=1; run(20);
    if(ok || rdi!=0) begin $display("FAIL one source to two sinks accepted");fails=fails+1;end
    if(fails==0) $display("PASS word network: SLIP, HDLC, chain, I2C gate, tagging, split, two at once, refusals");
    $finish(fails!=0);
  end
  initial begin #100000; $display("FAIL timeout"); $finish(1); end
endmodule
`default_nettype wire
