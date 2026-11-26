`default_nettype none
// The same control as i2c_target_fsm.v, one-hot: one register per state,
// as logic+state cells would hold it. ACK_LOW/ACK_HIGH merge into one
// "drive" state with a phase bit.
module i2c_target_onehot(input wire clk, rst_n, run,
  input wire scl, sda, scl_fall, start, stop, word, match,
  output wire drive_sda, coder_start, push_gate, done);
  reg free0, free1, idle, fire, addr, check, ack, low, high, next, skip, byte_, halt;
  wire go=rst_n && run;
  always @(posedge clk) begin
    if(!go) begin free0<=1; {free1,idle,fire,addr,check,ack,low,high,next,skip,byte_,halt}<=0; end
    else begin
      free0 <= (free0 && !sda) || (skip && stop);
      free1 <= (free0 && sda) || (free1 && !scl);
      idle  <= (free1 && scl) || (idle && !start);
      fire  <= (idle && start) || (skip && !stop && start);
      addr  <= fire || (addr && !word);
      check <= addr && word;
      ack   <= (check && match) || (ack && !scl_fall) || (byte_ && word);
      low   <= (ack && scl_fall) || (low && !scl);
      high  <= (low && scl) || (high && !scl_fall);
      next  <= high && scl_fall;
      skip  <= (check && !match) || (skip && !stop && !start);
      byte_ <= next || (byte_ && !word && !stop);
      halt  <= halt || (byte_ && !word && stop);
    end
  end
  assign drive_sda=low || high;
  assign coder_start=fire || next;
  assign push_gate=ack || low || high || next || byte_;
  assign done=halt;
endmodule
`default_nettype wire
