`timescale 1ns / 1ps

module program_memory_tb;
  reg        clk = 1'b0;
  reg        enable = 1'b0;
  reg        write_enable = 1'b0;
  reg        read_enable = 1'b0;
  reg  [9:0] address = 10'b0;
  reg  [7:0] write_data = 8'b0;
  reg  [7:0] write_mask = 8'b0;
  wire [7:0] read_data;

  always #5 clk = ~clk;

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

  task automatic write_byte(
      input [9:0] task_address,
      input [7:0] task_data,
      input [7:0] task_mask
  );
    begin
      @(negedge clk);
      enable = 1'b1;
      write_enable = 1'b1;
      address = task_address;
      write_data = task_data;
      write_mask = task_mask;
      @(posedge clk);
      #1;
      write_enable = 1'b0;
    end
  endtask

  task automatic read_byte(
      input [9:0] task_address,
      input [7:0] expected_data
  );
    begin
      @(negedge clk);
      enable = 1'b1;
      read_enable = 1'b1;
      address = task_address;
      @(posedge clk);
      #1;
      if (read_data !== expected_data)
        $fatal(1, "SRAM read mismatch: got %02x expected %02x", read_data, expected_data);
      read_enable = 1'b0;
    end
  endtask

  initial begin
    write_byte(10'h012, 8'h0f, 8'hff);
    read_byte(10'h012, 8'h0f);
    write_byte(10'h012, 8'ha0, 8'hf0);
    read_byte(10'h012, 8'haf);
    $display("program_memory_tb: PASS");
    $finish;
  end
endmodule
