`default_nettype none
// Matched finite shifter contracts for a block-boundary experiment. Payloads
// are pre-aligned: LSB-first starts at bit 0, MSB-first starts at bit 15.
module shift_lane(input wire clk, reset_n, input wire start, step, sample,
                  input wire msb_first, input wire [4:0] width,
                  input wire [15:0] tx, input wire serial_in,
                  output wire serial_out, output reg [15:0] rx,
                  output reg busy, output reg done);
  reg [15:0] data;
  reg [4:0] remaining;
  assign serial_out = msb_first ? data[15] : data[0];
  always @(posedge clk) begin
    if (!reset_n) begin data<=0; rx<=0; remaining<=0; busy<=0; done<=0; end
    else begin
      done<=0;
      if (start && !busy && width>=1 && width<=16) begin
        data<=tx; rx<=0; remaining<=width; busy<=1;
      end else if (busy) begin
        if (sample) rx<=msb_first ? {rx[14:0],serial_in} : {serial_in,rx[15:1]};
        if (step) begin
          data<=msb_first ? {data[14:0],1'b0} : {1'b0,data[15:1]};
          remaining<=remaining-1'b1;
          if (remaining==1) begin busy<=0; done<=1; end
        end
      end
    end
  end
endmodule

module pair_separate(input wire clk, reset_n, input wire [1:0] start, step, sample, msb_first,
                     input wire [9:0] width, input wire [31:0] tx, input wire [1:0] serial_in,
                     output wire [1:0] serial_out, output wire [31:0] rx,
                     output wire [1:0] busy, done, output wire compatible);
  assign compatible=1'b1;
  genvar i;
  generate for (i=0;i<2;i=i+1) begin: lane
    shift_lane unit(clk,reset_n,start[i],step[i],sample[i],msb_first[i],width[5*i+:5],
                    tx[16*i+:16],serial_in[i],serial_out[i],rx[16*i+:16],busy[i],done[i]);
  end endgenerate
endmodule

// Common start, width and step share one sequencer; data/order/sample remain
// independent. `compatible` exposes requests outside this common contract.
module pair_combined_shared(input wire clk, reset_n, input wire [1:0] start, step, sample, msb_first,
                            input wire [9:0] width, input wire [31:0] tx, input wire [1:0] serial_in,
                            output wire [1:0] serial_out, output reg [31:0] rx,
                            output wire [1:0] busy, done, output wire compatible);
  reg [31:0] data;
  reg [4:0] remaining;
  reg active, finished;
  assign busy={2{active}};
  assign done={2{finished}};
  assign compatible=(start[0]==start[1]) && (step[0]==step[1]) && (!start[0] || width[4:0]==width[9:5]);
  assign serial_out[0]=msb_first[0] ? data[15] : data[0];
  assign serial_out[1]=msb_first[1] ? data[31] : data[16];
  always @(posedge clk) begin
    if (!reset_n) begin data<=0; rx<=0; remaining<=0; active<=0; finished<=0; end
    else begin
      finished<=0;
      if (compatible && start[0] && !active && width[4:0]>=1 && width[4:0]<=16) begin
        data<=tx; rx<=0; remaining<=width[4:0]; active<=1;
      end else if (compatible && active) begin
        if (sample[0]) rx[15:0]<=msb_first[0] ? {rx[14:0],serial_in[0]} : {serial_in[0],rx[15:1]};
        if (sample[1]) rx[31:16]<=msb_first[1] ? {rx[30:16],serial_in[1]} : {serial_in[1],rx[31:17]};
        if (step[0]) begin
          data[15:0]<=msb_first[0] ? {data[14:0],1'b0} : {1'b0,data[15:1]};
          data[31:16]<=msb_first[1] ? {data[30:16],1'b0} : {1'b0,data[31:17]};
          remaining<=remaining-1'b1;
          if (remaining==1) begin active<=0; finished<=1; end
        end
      end
    end
  end
endmodule

// Combined packaging with independent sequencers: functionally the same as two
// separate lanes. Synthesis after flattening determines whether packaging helps.
module pair_combined_independent(input wire clk, reset_n, input wire [1:0] start, step, sample, msb_first,
                                 input wire [9:0] width, input wire [31:0] tx, input wire [1:0] serial_in,
                                 output wire [1:0] serial_out, output wire [31:0] rx,
                                 output wire [1:0] busy, done, output wire compatible);
  pair_separate pair(clk,reset_n,start,step,sample,msb_first,width,tx,serial_in,serial_out,rx,busy,done,compatible);
endmodule
`default_nettype wire
