`timescale 1ns/1ps
`default_nettype none
module equiv_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0, trigger=0, miso=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0;
  reg host_we=0;
  reg [1:0] host_addr=0;
  reg [15:0] host_wdata=16'ha500;
  wire [15:0] host_a,host_b;
  wire host_valid_a,host_valid_b;
  wire cs_a,sck_a,mosi_a,done_a,cs_b,sck_b,mosi_b,done_b;
  wire [2:0] oe_a,oe_b;
  wire [15:0] rx_a,rx_b;
  spi_fabric a(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,host_we,host_addr,host_wdata,host_a,host_valid_a,miso,
               cs_a,sck_a,mosi_a,oe_a,done_a,rx_a);
  spi_fixed_routes b(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,host_we,host_addr,host_wdata,host_b,host_valid_b,miso,
                     cs_b,sck_b,mosi_b,oe_b,done_b,rx_b);
  always @(posedge clk) begin
    #1;
    if (rst_n && {cs_a,sck_a,mosi_a,oe_a,done_a,rx_a,host_valid_a} !==
                 {cs_b,sck_b,mosi_b,oe_b,done_b,rx_b,host_valid_b})
      $fatal(1,"fixed and configured routes differ");
    if (rst_n && host_valid_a && host_a !== host_b) $fatal(1,"memory differs");
  end
  task write_cfg(input [4:0] address, input [15:0] data);
    begin
      @(negedge clk); cfg_we=1; cfg_addr=address; cfg_data=data;
      @(negedge clk); cfg_we=0;
    end
  endtask
  function [4:0] spi_row(input [3:0] row);
    case (row[3:2])
      0: spi_row = row[1] ? 5'h05 : 5'h00;
      1: spi_row = 5'h0e;
      2: spi_row = row[0] ? 5'h13 : 5'h06;
      3: spi_row = row[1] ? 5'h05 : 5'h13;
    endcase
  endfunction
  integer cycles=0, n;
  initial begin
    repeat (3) @(negedge clk); rst_n=1;
    @(negedge clk); host_we=1; @(negedge clk); host_we=0;
    write_cfg(0,16'h0808); write_cfg(1,16'h0000);
    for (n=0; n<16; n=n+1) write_cfg(n[4:0]+5'd2,{11'b0,spi_row(n[3:0])});
    @(negedge clk); arm=1; repeat (5) @(negedge clk);
    trigger=1; @(negedge clk); trigger=0;
    while (!done_a && cycles<400) begin
      @(negedge clk); cycles=cycles+1;
      // Exercise the synchronized input with a repeatable sequence.
      miso=cycles[3];
    end
    if (!done_a) $fatal(1,"timeout");
    repeat (3) @(negedge clk);
    $display("PASS: fixed and programmable zero-route mapping agree each cycle");
    $finish;
  end
endmodule
`default_nettype wire
