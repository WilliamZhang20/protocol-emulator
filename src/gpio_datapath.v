`default_nettype none

// Maps logical protocol signals onto physical GPIO pins.
// Applies masked output, output-enable, and compare operations.
// Captures pin samples and edge events for branching.
module gpio_datapath (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] pin_in,
    output wire [7:0] pin_out,
    output wire [7:0] pin_oe,
    input  wire       map_write,
    input  wire [2:0] logical_pin,
    input  wire [2:0] physical_pin,
    input  wire       output_write,
    input  wire [7:0] output_value,
    input  wire [7:0] output_mask,
    input  wire [7:0] oe_value,
    input  wire [7:0] oe_mask,
    input  wire [7:0] compare_value,
    input  wire [7:0] compare_mask,
    output wire [7:0] sampled_value,
    output wire [7:0] rising_edges,
    output wire [7:0] falling_edges,
    output wire       compare_match
);
  reg [7:0] logical_output;
  reg [7:0] logical_oe;
  reg [2:0] pin_map [0:7];
  reg [7:0] previous_sample;
  reg [7:0] physical_output;
  reg [7:0] physical_oe;
  reg [7:0] logical_sample;
  integer map_index;
  integer reset_index;

  always @(*) begin
    physical_output = 8'b0;
    physical_oe = 8'b0;
    logical_sample = 8'b0;
    for (map_index = 0; map_index < 8; map_index = map_index + 1) begin
      physical_output[pin_map[map_index]] = logical_output[map_index];
      physical_oe[pin_map[map_index]] = logical_oe[map_index];
      logical_sample[map_index] = pin_in[pin_map[map_index]];
    end
  end

  assign pin_out = physical_output;
  assign pin_oe = physical_oe;
  assign sampled_value = logical_sample;
  assign rising_edges = logical_sample & ~previous_sample;
  assign falling_edges = ~logical_sample & previous_sample;
  assign compare_match = (logical_sample & compare_mask) ==
                         (compare_value & compare_mask);

  always @(posedge clk) begin
    if (!rst_n) begin
      logical_output <= 8'b0;
      logical_oe <= 8'b0;
      previous_sample <= 8'b0;
      for (reset_index = 0; reset_index < 8; reset_index = reset_index + 1)
        pin_map[reset_index] <= reset_index[2:0];
    end else begin
      previous_sample <= logical_sample;
      if (map_write)
        pin_map[logical_pin] <= physical_pin;
      if (output_write) begin
        logical_output <= (logical_output & ~output_mask) |
                          (output_value & output_mask);
        logical_oe <= (logical_oe & ~oe_mask) | (oe_value & oe_mask);
      end
    end
  end
endmodule

`default_nettype wire
