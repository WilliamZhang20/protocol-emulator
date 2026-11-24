`timescale 1ns/1ps
// Standalone RTL-only stream test. Actor-stall coverage uses RTL hierarchy;
// this bench is not included in the gate-level cocotb modules.
module grid_stream_fabric_tb;
  reg clk=0,rst_n=0,arm=0,cfg_we=0,bank_cfg_we=0;
  reg [6:0] cfg_addr=0;reg [15:0] cfg_data=0;
  reg [1:0] bank_routes=0,pin_in=2'b11;
  reg host_req=0,host_we=0,tx_start=0,spi_start=0;
  reg [9:0] spi_source_addr=100,spi_dest_addr=200;
  wire spi_done,spi_error,spi_active;
  reg [9:0] host_addr=0,tx_base=100,rx_base=200;
  reg [10:0] tx_length=2,rx_capacity=2;
  reg [7:0] host_wdata=0;
  wire host_ready,host_rvalid,configured,tx_done,tx_error,rx_overflow,tx_active;
  wire [7:0] host_rdata;wire [2:0] pin_out,pin_oe,tx_queued,rx_queued;
  wire [10:0] rx_received,rx_written;
  grid_stream_fabric #(.USE_MACRO(1)) dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,
    bank_cfg_we,bank_routes,host_req,host_we,host_addr,host_wdata,host_ready,host_rvalid,host_rdata,
    tx_start,tx_base,tx_length,rx_base,rx_capacity,pin_in,pin_out,pin_oe,configured,
    tx_done,tx_error,rx_overflow,tx_active,rx_received,rx_written,tx_queued,rx_queued,
    spi_start,spi_source_addr,spi_dest_addr,spi_done,spi_error,spi_active);
  always #5 clk=~clk;
  initial begin #1000000;$fatal(1,"timeout");end
  // Interface-level invariants; evaluated with Verilator --assert.
  assert property (@(posedge clk) disable iff (!rst_n || !arm)
    tx_queued<=4 && rx_queued<=4 && rx_written<=rx_received);
  assert property (@(posedge clk) disable iff (!rst_n || !arm)
    rx_overflow |=> rx_overflow);
  assert property (@(posedge clk) disable iff (!rst_n || !arm)
    host_req && !host_ready |=> host_req && $stable({host_we,host_addr,host_wdata}));
  assert property (@(posedge clk) (!rst_n || !arm) |-> pin_oe==0);
  reg [15:0] image_words[0:65];
  string uart_image,spi_image;integer bit_period=16,stalls=0,actor_stalls=0;
  integer max_tx_queued=0,max_rx_queued=0;
  reg saw_tx_done=0;
  always @(posedge clk) if(arm) begin
    if(tx_done) saw_tx_done<=1;
    if(int'(tx_queued)>max_tx_queued) max_tx_queued<=int'(tx_queued);
    if(int'(rx_queued)>max_rx_queued) max_rx_queued<=int'(rx_queued);
    // Intentional RTL-only coverage: shared cocotb/GL tests do not use this bench.
    if(dut.rd_req && !dut.mem_ready[1]) actor_stalls<=actor_stalls+1;
  end
  task automatic cfg(input [6:0] a,input [15:0] v);
    begin @(negedge clk);cfg_addr=a;cfg_data=v;cfg_we=1;@(negedge clk);cfg_we=0;end
  endtask
  task automatic banks(input [1:0] v);
    begin @(negedge clk);bank_routes=v;bank_cfg_we=1;@(negedge clk);bank_cfg_we=0;end
  endtask
  task automatic host_write(input [9:0] a,input [7:0] v);
    begin @(negedge clk);host_addr=a;host_wdata=v;host_we=1;host_req=1;
      do @(posedge clk);while(!host_ready);@(negedge clk);host_req=0;host_we=0;end
  endtask
  task automatic host_read(input [9:0] a,input [7:0] v);
    begin @(negedge clk);host_addr=a;host_we=0;host_req=1;
      do @(posedge clk);while(!host_ready);#1;
      if(!host_rvalid || host_rdata!==v) $fatal(1,"read %0d got %h expected %h",a,host_rdata,v);
      @(negedge clk);host_req=0;end
  endtask
  task automatic load_image;
    integer k;
    begin
      if(uart_image=="") $fatal(1,"supply UART_IMAGE");
      $readmemh(uart_image,image_words);
      for(k=0;k<66;k=k+1) cfg(7'(k),image_words[k]);
      bit_period=int'(image_words[1]);
      if(!configured) $fatal(1,"invalid UART grid image");
    end
  endtask
  task automatic load_spi_image;
    integer k;
    begin
      if(spi_image=="") $fatal(1,"supply SPI_IMAGE");
      $readmemh(spi_image,image_words);
      for(k=0;k<66;k=k+1) cfg(7'(k),image_words[k]);
      if(!configured) $fatal(1,"invalid SPI grid image");
    end
  endtask
  task automatic spi_test(input bit alternate);
    integer k;reg [11:0] expected;
    begin
      expected=12'ha5c;spi_source_addr=100;spi_dest_addr=200;pin_in=2'b11;
      arm=1;host_write(100,8'h0a);host_write(101,8'h5c);
      fork
        begin @(negedge clk);spi_start=1;@(negedge clk);spi_start=0;end
        begin for(k=0;k<12;k=k+1) begin @(posedge pin_out[1]);#1;
          if(pin_out[2]!==0 || pin_out[0] !== (alternate ? 1'b0 : expected[11-k])) $fatal(1,"SPI bit %0d",k);
        end end
        begin @(posedge spi_done);end
      join
      if(spi_error) $fatal(1,"SPI error");
      host_read(200,8'h0f);host_read(201,8'hff);
      @(negedge clk);arm=0;#1;if(pin_oe!=0) $fatal(1,"SPI disarm");
    end
  endtask
  task automatic two_frame_test;
    integer k;reg [23:0] expected;
    begin
      expected=24'ha5c123;tx_length=4;rx_capacity=4;arm=1;pin_in=2'b11;
      host_write(100,8'h0a);host_write(101,8'h5c);host_write(102,8'h01);host_write(103,8'h23);
      fork
        begin @(negedge clk);spi_start=1;@(negedge clk);spi_start=0;end
        begin for(k=0;k<24;k=k+1) begin @(posedge pin_out[1]);#1;
          if(pin_out[0]!==expected[23-k]) $fatal(1,"repeated frame bit %0d",k);
        end end
        begin @(posedge spi_done);end
      join
      if(spi_error) $fatal(1,"repeated frame error");
      host_read(200,8'h0f);host_read(201,8'hff);host_read(202,8'h0f);host_read(203,8'hff);
      @(negedge clk);arm=0;tx_length=2;rx_capacity=2;
    end
  endtask
  task automatic split_bank_test;
    integer k;reg [11:0] expected;
    begin
      expected=12'ha5c;banks(0);cfg(88,4); // host/reader bank 0, writer bank 1
      arm=1;host_write(100,8'h0a);host_write(101,8'h5c);
      fork
        begin @(negedge clk);spi_start=1;@(negedge clk);spi_start=0;end
        begin for(k=0;k<12;k=k+1) begin @(posedge pin_out[1]);#1;
          if(pin_out[0]!==expected[11-k]) $fatal(1,"split-bank bit %0d",k);
        end end
        begin @(posedge spi_done);end
      join
      if(spi_error) $fatal(1,"split-bank transfer failed");
      @(negedge clk);arm=0;banks(3);@(negedge clk);arm=1;
      host_read(200,8'h0f);host_read(201,8'hff);
      @(negedge clk);arm=0;
    end
  endtask
  task automatic expect_length_error(input [10:0] txlen,input [10:0] rxlen);
    integer n;
    begin
      @(negedge clk);arm=0;tx_length=txlen;rx_capacity=rxlen;
      @(negedge clk);arm=1;@(negedge clk);spi_start=1;@(negedge clk);spi_start=0;
      for(n=0;n<1000 && !spi_done;n=n+1) @(negedge clk);
      if(!spi_done || !spi_error || spi_active) $fatal(1,"length mismatch did not fail: tx=%0d rx=%0d",txlen,rxlen);
      @(negedge clk);arm=0;tx_length=2;rx_capacity=2;
    end
  endtask
  task automatic send_byte(input [7:0] value);
    integer n;
    begin
      @(negedge clk);pin_in[1]=0;repeat(bit_period) @(negedge clk);
      for(n=0;n<8;n=n+1) begin pin_in[1]=value[n];repeat(bit_period) @(negedge clk);end
      pin_in[1]=1;repeat(bit_period) @(negedge clk);
    end
  endtask
  task automatic check_byte(input [7:0] value);
    integer n;
    begin
      @(negedge pin_out[0]);repeat(bit_period/2) @(posedge clk);#1;
      if(pin_out[0]!==0) $fatal(1,"bad TX start");
      for(n=0;n<8;n=n+1) begin repeat(bit_period) @(posedge clk);#1;
        if(pin_out[0]!==value[n]) $fatal(1,"bad TX bit %0d expected byte %h",n,value);end
      repeat(bit_period) @(posedge clk);#1;if(pin_out[0]!==1) $fatal(1,"bad TX stop");
    end
  endtask
  task automatic start_tx(input [9:0] base,input [10:0] length);
    begin @(negedge clk);tx_base=base;tx_length=length;tx_start=1;@(negedge clk);tx_start=0;end
  endtask
  task automatic traffic(input integer cycles);
    integer n;
    reg accepted;
    begin
      @(negedge clk);host_req=1;host_we=1;host_addr=500;host_wdata=8'had;
      for(n=0;n<cycles;n=n+1) begin
        @(posedge clk);accepted=host_ready;if(!accepted) stalls=stalls+1;
        @(negedge clk);
        if(accepted) host_addr=10'd500+10'(n%400);
      end
      while(!accepted) begin @(posedge clk);accepted=host_ready;@(negedge clk);end
      host_req=0;host_we=0;
    end
  endtask
  initial begin
    if(!$value$plusargs("UART_IMAGE=%s",uart_image)) uart_image="";
    if(!$value$plusargs("SPI_IMAGE=%s",spi_image)) spi_image="";
    repeat(2) @(negedge clk);rst_n=1;load_spi_image();
    banks(2'b00);spi_test(0);
    banks(2'b11);spi_test(0);
    split_bank_test();banks(3);
    two_frame_test();
    expect_length_error(3,4);expect_length_error(2,1);expect_length_error(2,3);expect_length_error(4,2);
    cfg(20,image_words[20] & 16'hfff8);spi_test(1); // disconnect MOSI at its first grid link
    cfg(48,22);@(negedge clk);arm=1;#1;
    if(configured || pin_oe!=0) $fatal(1,"invalid grid selector must disable outputs");
    @(negedge clk);arm=0;
    cfg(48,image_words[48]);cfg(63,16'h2005);
    spi_source_addr=1023;tx_base=1023;@(negedge clk);arm=1;
    @(negedge clk);spi_start=1;@(negedge clk);spi_start=0;
    if(!spi_done || !spi_error || spi_active) $fatal(1,"dual-lane source range not rejected");
    @(negedge clk);arm=0;spi_source_addr=100;tx_base=100;rx_capacity=16;saw_tx_done=0;
    load_image();
    // Host preloads TX; receiver is enabled but receives no serial input.
    arm=1;repeat(3) @(negedge clk);
    host_write(100,8'h53);host_write(101,8'ha6);host_write(102,8'h19);
    // Receive-only: five back-to-back bytes wrap the four-entry queue indices.
    send_byte(8'h12);send_byte(8'ha5);send_byte(8'h7e);send_byte(8'h32);send_byte(8'hc1);
    repeat(20) @(negedge clk);
    if(tx_active || saw_tx_done || rx_received!=5 || rx_written!=5 || rx_overflow) $fatal(1,"receive-only status");
    host_read(200,8'h12);host_read(201,8'ha5);host_read(202,8'h7e);
    host_read(203,8'h32);host_read(204,8'hc1);
    // Transmit-only: three bytes from SRAM, no receive traffic.
    saw_tx_done=0;
    fork
      start_tx(100,3);
      begin check_byte(8'h53);check_byte(8'ha6);check_byte(8'h19);end
      // After the first actor grant, collide a host write with the next actor
      // request while round-robin priority favors the host. RTL-only coverage.
      begin
        wait(dut.rd_req);@(posedge clk);
        wait(!dut.rd_req);wait(dut.rd_req);
        host_write(450,8'h35);
      end
    join
    repeat(bit_period+10) @(negedge clk);
    if(!saw_tx_done || tx_error || tx_active || rx_received!=5 || max_tx_queued<2 || max_rx_queued<1 || actor_stalls==0)
      $fatal(1,"stream queues/status done=%0d error=%0d active=%0d rx=%0d txqmax=%0d rxqmax=%0d actor_stalls=%0d",saw_tx_done,tx_error,tx_active,rx_received,max_tx_queued,max_rx_queued,actor_stalls);
    // A second request without disarming exercises TX queue pointer wrap.
    saw_tx_done=0;
    fork
      start_tx(101,2);
      begin check_byte(8'ha6);check_byte(8'h19);end
    join
    repeat(bit_period+10) @(negedge clk);
    if(!saw_tx_done || tx_error || tx_active) $fatal(1,"second TX request failed");
    // Fresh bounded receive area, deliberately overflow after two bytes.
    @(negedge clk);arm=0;rx_base=300;rx_capacity=2;
    @(negedge clk);arm=1;repeat(3) @(negedge clk);host_write(302,8'hc7);
    saw_tx_done=0;stalls=0;
    fork
      start_tx(100,3);
      begin check_byte(8'h53);check_byte(8'ha6);check_byte(8'h19);end
      begin send_byte(8'h44);send_byte(8'h81);send_byte(8'hfe);end
      traffic(35*bit_period);
    join
    repeat(20) @(negedge clk);
    if(!saw_tx_done || tx_error || tx_active || rx_received!=2 || rx_written!=2 || !rx_overflow || stalls==0 || actor_stalls==0)
      $fatal(1,"concurrent status txdone=%0d txerr=%0d active=%0d rx=%0d wr=%0d ov=%0d host_stalls=%0d actor_stalls=%0d",saw_tx_done,tx_error,tx_active,rx_received,rx_written,rx_overflow,stalls,actor_stalls);
    host_read(300,8'h44);host_read(301,8'h81);host_read(302,8'hc7);
    // Sticky overflow clears only by disarm; out-of-range TX fails closed.
    @(negedge clk);arm=0;@(negedge clk);arm=1;repeat(3) @(negedge clk);
    if(rx_overflow) $fatal(1,"overflow did not clear on disarm");
    saw_tx_done=0;start_tx(1023,2);repeat(4) @(negedge clk);
    if(!saw_tx_done || !tx_error || tx_active) $fatal(1,"invalid TX range accepted");
    saw_tx_done=0;start_tx(1023,2047);repeat(4) @(negedge clk);
    if(!saw_tx_done || !tx_error || tx_active) $fatal(1,"overflowing TX range accepted");
    @(negedge clk);arm=0;rx_base=1023;rx_capacity=2;
    @(negedge clk);arm=1;repeat(3) @(negedge clk);
    if(!rx_overflow || rx_received!=0 || rx_written!=0) $fatal(1,"invalid RX range accepted");
    @(negedge clk);arm=0;#1;if(pin_oe!=0) $fatal(1,"pin enable on disarm");
    $display("PASS: compiler-routed grid runs SPI, then receive-only, transmit-only and concurrent UART with contention and overflow");
    $finish;
  end
endmodule
