`default_nettype none
// Control of the I2C target (program B, FABRIC_REORG.md) as a plain state
// machine, to count the logic+state cells it needs (yosys -> 4-input LUTs).
// Inputs are the routed events; outputs are the actions.
module i2c_target_fsm(input wire clk, rst_n, run,
  input wire scl, sda, scl_fall, start, stop, word, match,
  output wire drive_sda, coder_start, push_gate, done);
  localparam FREE0=0, FREE1=1, IDLE=2, FIRE=4, ADDR=5, CHECK=6, ACK=7, ACK_LOW=8,
             ACK_HIGH=9, NEXT=10, SKIP=11, BYTE=12, HALT=15;
  reg [3:0] st;
  always @(posedge clk) begin
    if(!rst_n || !run) st<=FREE0;
    else case(st)
      FREE0: if(sda) st<=FREE1;
      FREE1: if(scl) st<=IDLE;
      IDLE: if(start) st<=FIRE;
      FIRE: st<=ADDR;
      ADDR: if(word) st<=CHECK;
      CHECK: st<=match ? ACK : SKIP;
      ACK: if(scl_fall) st<=ACK_LOW;
      ACK_LOW: if(scl) st<=ACK_HIGH;
      ACK_HIGH: if(scl_fall) st<=NEXT;
      NEXT: st<=BYTE;
      SKIP: if(stop) st<=FREE0; else if(start) st<=FIRE;
      BYTE: if(word) st<=ACK; else if(stop) st<=HALT;
      default: st<=HALT;
    endcase
  end
  assign drive_sda=st==ACK_LOW || st==ACK_HIGH;
  assign coder_start=st==FIRE || st==NEXT;
  assign push_gate=st==ACK || st==ACK_LOW || st==ACK_HIGH || st==NEXT || st==BYTE;
  assign done=st==HALT;
endmodule
`default_nettype wire
