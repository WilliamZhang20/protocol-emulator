`default_nettype none
// Experimental tile contracts. They do not replace the current chip top.
// Config writes are accepted only while disarmed; zero periods are invalid.
module fabric_v2_timer(
    input wire clk, rst_n, arm, cfg_we,
    input wire [15:0] cfg_first, cfg_period,
    input wire start, stop, hold,
    output reg tick, running, output wire configured,
    output reg level, rise, fall);
  reg [15:0] first, period, remaining;
  reg valid;
  assign configured=valid;
  always @(posedge clk) begin
    if (!rst_n) begin
      first<=0; period<=0; remaining<=0; valid<=0; tick<=0; running<=0; level<=0; rise<=0; fall<=0;
    end else begin
      tick<=0; rise<=0; fall<=0;
      if (!arm) begin
        running<=0; remaining<=0; level<=0;
        if (cfg_we) begin
          first<=cfg_first; period<=cfg_period;
          valid<=(cfg_first!=0 && cfg_period!=0);
        end
      end else if (stop) begin
        running<=0; remaining<=0; level<=0;
      end else if (start && valid && !running) begin
        running<=1; remaining<=first;
      end else if (running && !hold) begin
        if (remaining==1) begin
          tick<=1; remaining<=period; level<=!level;
          if (level) fall<=1; else rise<=1;
        end
        else remaining<=remaining-1'b1;
      end
    end
  end
endmodule

// Width is 1..16. TX and RX words are right aligned. For MSB-first the first
// serial bit is tx[width-1]; for LSB-first it is tx[0]. Sampling and shifting
// are independent events. At most width samples are captured per transfer.
module fabric_v2_shift(
    input wire clk, rst_n, arm, start, shift, sample,
    input wire [4:0] width, input wire msb_first,
    input wire [15:0] tx, input wire serial_in,
    output wire serial_out, output reg [15:0] rx,
    output reg busy, done);
  reg [15:0] data;
  reg [4:0] active_width, shift_count, sample_count;
  reg active_msb;
  wire [4:0] out_index=active_msb ? active_width-1'b1 : 5'd0;
  wire [4:0] sample_index=active_msb ? active_width-1'b1-sample_count : sample_count;
  assign serial_out=busy ? data[out_index[3:0]] : 1'b0;
  always @(posedge clk) begin
    if (!rst_n || !arm) begin
      data<=0; rx<=0; active_width<=0; shift_count<=0; sample_count<=0;
      active_msb<=0; busy<=0; done<=0;
    end else begin
      done<=0;
      if (start && !busy && width>=1 && width<=16) begin
        data<=tx; rx<=0; active_width<=width; shift_count<=0; sample_count<=0;
        active_msb<=msb_first; busy<=1;
      end else if (busy) begin
        if (sample && sample_count<active_width) begin
          rx[sample_index[3:0]]<=serial_in; sample_count<=sample_count+1'b1;
        end
        if (shift) begin
          data<=active_msb ? {data[14:0],1'b0} : {1'b0,data[15:1]};
          shift_count<=shift_count+1'b1;
          if (shift_count+1'b1==active_width) begin busy<=0;done<=1;end
        end
      end
    end
  end
endmodule
`default_nettype wire
