`timescale 1ns/1ps
`default_nettype none
// A sustained same-bank conflict must alternate. This bench deliberately has
// no scoreboard: its failure on a broken arbiter must come from the SVA.
module memory_assertion_mutation_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0;
  reg [1:0] req=0;
  wire [1:0] ready, valid;
  wire [15:0] data;
  experiment_memory_fabric dut(clk,rst_n,arm,1'b0,2'b00,req,2'b00,20'd0,16'd0,ready,valid,data);
  memory_contract_assertions check_contract(clk,rst_n,arm,1'b0,2'b00,req,2'b00,20'd0,16'd0,ready,valid);
  initial begin
    repeat (3) @(negedge clk); rst_n=1; arm=1; req=2'b11;
    repeat (8) @(negedge clk);
    $display("PASS: fairness assertions accepted correct arbiter");
    $finish;
  end
endmodule
`default_nettype wire
