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

  (* anyconst *) reg [9:0] tracked_address;
  reg [7:0] tracked_data;
  reg [7:0] expected_read;
  reg       tracked_valid = 1'b0;
  reg       read_pending = 1'b0;

  wire tracked_write = enable && write_enable && address == tracked_address;
  wire tracked_read = enable && read_enable && address == tracked_address;
  wire full_write = &write_mask;
  wire [7:0] merged_data = (tracked_data & ~write_mask) |
                           (write_data & write_mask);

  always @(posedge clk) begin
    if (read_pending)
      assert(read_data == expected_read);

    read_pending <= 1'b0;

    if (tracked_write) begin
      if (tracked_valid)
        tracked_data <= merged_data;
      else if (full_write) begin
        tracked_data <= write_data;
        tracked_valid <= 1'b1;
      end
    end

    if (tracked_read && (tracked_valid || (tracked_write && full_write))) begin
      read_pending <= 1'b1;
      expected_read <= tracked_write
          ? (tracked_valid ? merged_data : write_data)
          : tracked_data;
    end

    cover(tracked_valid && read_pending);
    cover(tracked_valid && tracked_write && write_mask != 8'h00 &&
          write_mask != 8'hff);
  end

endmodule

`default_nettype wire
