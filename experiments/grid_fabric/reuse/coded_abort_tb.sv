`timescale 1ns/1ps
// RTL-only fault injection: the SRAM reader's delivered valid is held low at
// a word boundary. This bench is not part of COCOTB_TEST_MODULES or GL tests.
module coded_abort_tb;
  reg clk=0,rst_n=0,arm=0,cfg_we=0,bank_cfg_we=0;
  reg [6:0] cfg_addr=0;reg [15:0] cfg_data=0;
  reg [1:0] bank_routes=0,pin_in=2'b11;
  reg host_req=0,host_we=0,tx_start=0,spi_start=0;
  reg [9:0] host_addr=0,tx_base=100,rx_base=200;
  reg [10:0] tx_length=8,rx_capacity=0;
  reg [7:0] host_wdata=0;
  wire host_ready,host_rvalid,configured,tx_done,tx_error,rx_overflow,tx_active;
  wire spi_done,spi_error,spi_active;wire [7:0] host_rdata;
  wire [2:0] pin_out,pin_oe,tx_queued,rx_queued;wire [10:0] rx_received,rx_written;
  grid_stream_fabric #(.USE_MACRO(1)) dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,
    bank_cfg_we,bank_routes,host_req,host_we,host_addr,host_wdata,host_ready,host_rvalid,host_rdata,
    tx_start,tx_base,tx_length,rx_base,rx_capacity,pin_in,pin_out,pin_oe,configured,
    tx_done,tx_error,rx_overflow,tx_active,rx_received,rx_written,tx_queued,rx_queued,
    spi_start,10'd100,10'd200,spi_done,spi_error,spi_active);
  always #5 clk=~clk;
  initial begin #1000000;$fatal(1,"coded abort test timeout");end
  reg [15:0] words[0:123];reg [7:0] payload[0:7];integer i;
  task automatic cfg(input [6:0] a,input [15:0] v);
    begin @(negedge clk);cfg_addr=a;cfg_data=v;cfg_we=1;@(negedge clk);cfg_we=0;end
  endtask
  task automatic write_byte(input [9:0] a,input [7:0] v);
    begin @(negedge clk);host_addr=a;host_wdata=v;host_we=1;host_req=1;
      do @(posedge clk);while(!host_ready);@(negedge clk);host_req=0;host_we=0;end
  endtask
  task automatic launch;
    begin @(negedge clk);tx_start=1;@(negedge clk);tx_start=0;end
  endtask
  initial begin
    $readmemh("test/data/grid-usb-coded.mem",words);
    payload[0]=8'h80;payload[1]=8'hc3;payload[2]=8'h01;payload[3]=8'hff;
    payload[4]=8'hff;payload[5]=8'h80;payload[6]=8'h7e;payload[7]=8'h3f;
    repeat(4) @(negedge clk);rst_n=1;
    for(i=0;i<124;i=i+1)cfg(7'(i),words[i]);
    if(!configured)$fatal(1,"coded image rejected");
    @(negedge clk);arm=1;
    for(i=0;i<8;i=i+1)write_byte(10'(100+i),payload[i]);
    launch();
    wait(dut.packet_started && dut.packet_left==7);
    @(negedge clk);force dut.rd_valid=1'b0;
    @(posedge tx_done);#1;
    if(!tx_error)$fatal(1,"missing packet underrun error");
    if(pin_oe[1:0]!=0)$fatal(1,"USB pins remained driven after abort");
    @(negedge clk);release dut.rd_valid;
    repeat(20) @(negedge clk);
    launch();
    @(posedge tx_done);#1;
    if(tx_error)$fatal(1,"coded reader failed to recover after abort");
    $display("PASS: coded stream underrun aborts, drains and restarts");
    $finish;
  end
endmodule
