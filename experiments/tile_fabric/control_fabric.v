`default_nettype none

// Complete but deliberately narrow target: two synchronized Boolean inputs,
// one configured control tile, three registered pulse-output paths, and
// individually enabled output pads. It does not implement timers, shifters,
// streams, runtime host functions, SRAM, or the existing chip's host link.
module control_fabric(input wire clk, input wire rst_n, input wire arm,
                      input wire cfg_we, input wire [4:0] cfg_addr,
                      input wire [15:0] cfg_data, input wire [1:0] pad_in,
                      output reg [2:0] pad_out, output reg [2:0] pad_oe);
  reg [16:0] written;
  reg [2:0] output_mask;
  reg mask_valid;
  wire active = arm && (&written) && mask_valid;
  wire control_write = rst_n && !arm && cfg_we && cfg_addr < 16;
  wire a, b, action1, action2, action3;
  reg [2:0] output_registers;

  always @(posedge clk) begin
    if (!rst_n) begin written <= 0; output_mask <= 0; mask_valid <= 0; end
    else if (!arm && cfg_we && cfg_addr <= 16) begin
      written[cfg_addr] <= 1;
      if (cfg_addr == 16) begin
        output_mask <= cfg_data[2:0];
        mask_valid <= cfg_data[15:3] == 0;
      end
    end
  end

  proto_pin_in input0(clk,rst_n,pad_in[0],a);
  proto_pin_in input1(clk,rst_n,pad_in[1],b);
  proto_control control(clk,rst_n,active,control_write,cfg_addr[3:0],cfg_data[4:0],
                        a,b,action1,action2,action3);
  // The first register represents each source `reg`; the second represents
  // the pin's registered output. One register per action is available.
  always @(posedge clk) begin
    if (!rst_n || !active) begin output_registers <= 0; pad_out <= 0; pad_oe <= 0; end
    else begin
      output_registers <= {action3,action2,action1};
      pad_out <= output_registers;
      pad_oe <= output_mask;
    end
  end
endmodule
`default_nettype wire
