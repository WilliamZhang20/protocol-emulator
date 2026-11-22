`timescale 1ns/1ps
`default_nettype none
module equiv_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0, cfg_addr=0, trigger=0, miso=0;
  reg [15:0] cfg_data=0;
  reg [7:0] tx_word=8'ha5;
  wire cs_a,sck_a,mosi_a,done_a,cs_b,sck_b,mosi_b,done_b;
  wire [2:0] oe_a,oe_b;
  wire [7:0] rx_a,rx_b;
  spi_fabric a(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,tx_word,miso,
               cs_a,sck_a,mosi_a,oe_a,done_a,rx_a);
  spi_fixed_routes b(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,tx_word,miso,
                     cs_b,sck_b,mosi_b,oe_b,done_b,rx_b);
  always @(posedge clk) begin
    #1;
    if (rst_n && {cs_a,sck_a,mosi_a,oe_a,done_a,rx_a} !==
                 {cs_b,sck_b,mosi_b,oe_b,done_b,rx_b})
      $fatal(1,"fixed and configured routes differ");
  end
  task write_cfg(input reg address, input [15:0] data);
    begin
      @(negedge clk); cfg_we=1; cfg_addr=address; cfg_data=data;
      @(negedge clk); cfg_we=0;
    end
  endtask
  integer cycles=0;
  initial begin
    repeat (3) @(negedge clk); rst_n=1;
    write_cfg(0,16'h0808); write_cfg(1,16'h0000);
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
