`timescale 1ns/1ps

module fabric_control_actor_2input_tb;
  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;
  reg enable = 1'b0;
  reg cfg_we = 1'b0;
  reg [7:0] cfg_addr = 8'd0;
  reg [15:0] cfg_data = 16'd0;
  reg [63:0] lines = 64'd0;
  wire [2:0] action;

  fabric_control_actor #(.ACTOR(0)) dut (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .cfg_we(cfg_we),
      .cfg_addr(cfg_addr),
      .cfg_data(cfg_data),
      .lines(lines),
      .action(action)
  );

  task automatic write_config(input [7:0] address, input [15:0] data);
    begin
      @(negedge clk);
      cfg_we = 1'b1;
      cfg_addr = address;
      cfg_data = data;
      @(posedge clk);
      #1;
      cfg_we = 1'b0;
    end
  endtask

  task automatic check_inputs(input bit tick, input bit ack, input [2:0] expected);
    begin
      @(negedge clk);
      lines = 64'd0;
      lines[4] = tick;
      lines[32] = ack;
      @(posedge clk);
      #1;
      if (action !== expected) begin
        $error("tick=%0d ack=%0d expected action=%b, got %b", tick, ack, expected, action);
        $fatal(1);
      end
    end
  endtask

  integer state_index;
  reg [5:0] high_row;
  initial begin
    @(posedge clk);
    #1;
    rst_n = 1'b1;
    enable = 1'b1;

    // Select signal-space lines 4 and 32. Pack rows 0/1 and 2/3.
    write_config(8'hA0, 16'd2052);
    write_config(8'h90, 16'd128); // tick=1, ack=0 -> action 1
    write_config(8'h91, 16'd256); // tick=1, ack=1 -> action 2

    check_inputs(1'b0, 1'b0, 3'b000);
    check_inputs(1'b1, 1'b0, 3'b001);
    check_inputs(1'b0, 1'b1, 3'b000);
    check_inputs(1'b1, 1'b1, 3'b010);
    check_inputs(1'b0, 1'b0, 3'b000);

    // In wide mode, visit all eight states, advancing on each high sample.
    // State 7 emits a different action so reaching it is externally observable.
    @(negedge clk);
    enable = 1'b0;
    write_config(8'hA0, 16'h1004);
    for (state_index = 0; state_index < 8; state_index = state_index + 1) begin
      high_row = {state_index == 7 ? 3'b010 : 3'b001, 3'(state_index + 1)};
      write_config(8'h90 + 8'(state_index), {4'b0, high_row, 3'b000, 3'(state_index)});
    end
    @(negedge clk);
    enable = 1'b1;
    for (state_index = 0; state_index < 8; state_index = state_index + 1) begin
      check_inputs(1'b1, 1'b0, state_index == 7 ? 3'b010 : 3'b001);
      check_inputs(1'b0, 1'b0, 3'b000);
    end

    $display("PASS: two-input and eight-state actor modes");
    $finish;
  end
endmodule
