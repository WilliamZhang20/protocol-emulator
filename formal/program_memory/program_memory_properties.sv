`default_nettype none

module program_memory_properties (
    input wire       clk,
    input wire       enable,
    input wire       write_enable,
    input wire       read_enable,
    input wire [9:0] address,
    input wire [7:0] write_data,
    input wire [7:0] write_mask
);
  wire [7:0] read_data;

  program_memory dut (
      .clk(clk),
      .enable(enable),
      .write_enable(write_enable),
      .read_enable(read_enable),
      .address(address),
      .write_data(write_data),
      .write_mask(write_mask),
      .read_data(read_data)
  );

  always @(posedge clk) begin
    cover(enable && write_enable && &write_mask);
    cover(enable && write_enable && write_mask != 8'h00 &&
          write_mask != 8'hff);
    cover(enable && read_enable);
  end
endmodule

`default_nettype wire
