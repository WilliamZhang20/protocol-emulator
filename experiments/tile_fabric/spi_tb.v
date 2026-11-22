`timescale 1ns/1ps
`default_nettype none
module spi_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, trigger=0, miso=0, cfg_we=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0;
  reg [7:0] half_period=8;
  reg [15:0] tx_word=16'ha500;
  reg [4:0] width=8;
  reg host_we=0;
  reg [1:0] host_addr=0;
  reg [15:0] host_wdata=0;
  wire [15:0] host_rdata;
  wire host_rvalid;
  wire cs, sck, mosi, done;
  wire [2:0] oe;
  wire [15:0] rx_word;
  reg [15:0] image [0:18];
  reg [1023:0] image_path;
  integer use_image;
  initial begin
    use_image=$value$plusargs("IMAGE=%s",image_path);
    if (use_image != 0) $readmemh(image_path,image);
  end
  spi_fabric dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,host_we,host_addr,host_wdata,host_rdata,host_rvalid,miso,
                 cs,sck,mosi,oe,done,rx_word);

  // Exercise every input and selector value of the same junction used by
  // the fabric, including configurations not needed by the SPI mapping.
  reg [3:0] route_sources=0;
  reg [1:0] route_sel=0;
  wire route_out;
  reg route_tests_done=0;
  integer route_i, route_j;
  proto_route route_probe(clk,rst_n,route_sel,route_sources,route_out);
  initial begin
    wait(rst_n);
    for (route_i=0; route_i<4; route_i=route_i+1) begin
      for (route_j=0; route_j<16; route_j=route_j+1) begin
        @(negedge clk); route_sel=route_i[1:0]; route_sources=route_j[3:0];
        @(posedge clk); #1;
        if (route_out !== route_sources[route_sel])
          $fatal(1,"route selector %0d sources %h",route_i,route_sources);
      end
    end
    route_tests_done=1;
  end

  task write_cfg(input [4:0] address, input [15:0] data);
    begin
      @(negedge clk); cfg_we=1; cfg_addr=address; cfg_data=data;
      @(negedge clk); cfg_we=0;
    end
  endtask

  task write_tx(input [15:0] data);
    begin
      @(negedge clk); host_we=1; host_addr=0; host_wdata=data;
      @(negedge clk); host_we=0;
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
  task load_control;
    integer n;
    begin
      for (n=0; n<16; n=n+1)
        write_cfg(n[4:0]+5'd2, use_image != 0 ? image[n+2] : {11'b0,spi_row(n[3:0])});
    end
  endtask

  // Pin-level mode-0 peripheral: preload reply bit 7, sample MOSI on rising
  // edges, and update the next MISO bit on falling edges. No DUT hierarchy.
  integer bit_index=0, cycles=0, tick=0, last_edge=-1, edge_count=0;
  reg [15:0] observed=0;
  reg [15:0] reply=16'h5a30;
  reg old_sck=0, old_mosi=0;
  always @(negedge clk) begin
    tick = tick + 1;
    if (arm && oe == 3'b111 && !cs) begin
      if (sck != old_sck) begin
        if (last_edge >= 0 && tick-last_edge != {24'd0, half_period})
          $fatal(1,"wrong half period: %0d",tick-last_edge);
        last_edge = tick;
        edge_count = edge_count + 1;
      end
      if (!old_sck && sck) begin
        if (mosi !== old_mosi) $fatal(1,"MOSI changed on sampling edge");
        observed = {observed[14:0], mosi};
        bit_index = bit_index + 1;
      end
      if (old_sck && !sck && bit_index < {27'd0, width})
        miso = reply[15-bit_index];
    end
    old_sck = sck;
    old_mosi = mosi;
  end

  initial begin
    repeat (3) @(negedge clk); rst_n=1;
    // A partial image cannot arm; all control rows must also be written.
    write_cfg(0, use_image != 0 ? image[0] : 16'h0808);
    @(negedge clk); arm=1; repeat (3) @(negedge clk);
    if (oe !== 0) $fatal(1,"incomplete configuration drove pins");
    arm=0; write_cfg(1, use_image != 0 ? image[1] : 16'h0000);
    @(negedge clk); arm=1; repeat (3) @(negedge clk);
    if (oe !== 0) $fatal(1,"missing control rows drove pins");
    arm=0; load_control();
    // A complete configuration cannot arm until TX payload is present.
    arm=1; repeat (3) @(negedge clk);
    if (oe !== 0) $fatal(1,"missing TX payload drove pins");
    arm=0; write_tx(use_image != 0 ? image[18] : tx_word);
    @(negedge clk); arm=1; miso=0;
    repeat (5) @(negedge clk);
    if (oe !== 3'b111 || cs !== 1 || sck !== 0) $fatal(1,"bad idle");
    // This attempted MOSI reroute must be ignored while armed.
    write_cfg(1, 16'h0c00);
    // Payload writes while armed are also ignored: TX must remain 0xA5.
    write_tx(16'h0000);
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles < 400) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0 || bit_index != 8 || edge_count != 16 || observed !== 16'h00a5 || rx_word !== 16'h005a)
      $fatal(1,"SPI failed: done=%b cs=%b sck=%b samples=%0d edges=%0d tx=%h rx=%h",done,cs,sck,bit_index,edge_count,observed,rx_word);
    host_addr=1; #1;
    if (!host_rvalid || host_rdata !== 16'h005a) $fatal(1,"local RX store mismatch");
    if (!route_tests_done) $fatal(1,"route matrix test incomplete");
    $display("SPI exchange: tx=%h rx=%h, %0d cycles",observed,rx_word,cycles);
    arm=0; repeat (2) @(negedge clk);
    if (oe !== 0) $fatal(1,"disarm did not release pins");
    // Same physical tiles/routes, different width: five MSB-first bits.
    bit_index=0; edge_count=0; last_edge=-1; observed=0; cycles=0;
    width=5; tx_word=16'ha800; miso=0;
    write_cfg(0, 16'h0508); write_tx(tx_word); arm=1; repeat (5) @(negedge clk);
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles < 400) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0 || bit_index != 5 || edge_count != 10 || observed !== 16'h0015 || rx_word !== 16'h000b)
      $fatal(1,"5-bit SPI failed: samples=%0d edges=%0d tx=%h rx=%h",bit_index,edge_count,observed,rx_word);
    host_addr=1; #1;
    if (!host_rvalid || host_rdata !== 16'h000b) $fatal(1,"5-bit local RX store mismatch");
    $display("5-bit exchange: tx=%h rx=%h, %0d cycles",observed,rx_word,cycles);
    arm=0; repeat (2) @(negedge clk);
    // Twelve bits exercise a non-byte width larger than the old prototype.
    bit_index=0; edge_count=0; last_edge=-1; observed=0; cycles=0;
    width=12; tx_word=16'ha5c0; miso=0;
    write_cfg(0, 16'h0c08); write_tx(tx_word); arm=1; repeat (5) @(negedge clk);
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles < 400) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0 || bit_index != 12 || edge_count != 24 || observed !== 16'h0a5c || rx_word !== 16'h05a3)
      $fatal(1,"12-bit SPI failed: samples=%0d edges=%0d tx=%h rx=%h",bit_index,edge_count,observed,rx_word);
    host_addr=1; #1;
    if (!host_rvalid || host_rdata !== 16'h05a3) $fatal(1,"12-bit local RX store mismatch");
    $display("12-bit exchange: tx=%h rx=%h, %0d cycles",observed,rx_word,cycles);
    arm=0; repeat (2) @(negedge clk);
    bit_index=0; edge_count=0; last_edge=-1; observed=0; cycles=0;
    width=16; tx_word=16'ha5c3; miso=0;
    write_cfg(0, 16'h1008); write_tx(tx_word); arm=1; repeat (5) @(negedge clk);
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles < 400) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0 || bit_index != 16 || edge_count != 32 || observed !== 16'ha5c3 || rx_word !== 16'h5a30)
      $fatal(1,"16-bit SPI failed: samples=%0d edges=%0d tx=%h rx=%h",bit_index,edge_count,observed,rx_word);
    host_addr=1; #1;
    if (!host_rvalid || host_rdata !== 16'h5a30) $fatal(1,"16-bit local RX store mismatch");
    $display("16-bit exchange: tx=%h rx=%h, %0d cycles",observed,rx_word,cycles);
    arm=0; repeat (2) @(negedge clk);
    // Change two table rows: a trigger now completes immediately without
    // selecting the device or starting the shift/timer tiles.
    write_cfg(4, 16'h0013); write_cfg(5, 16'h0013);
    arm=1; repeat (5) @(negedge clk);
    trigger=1; @(negedge clk); trigger=0;
    repeat (4) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0) $fatal(1,"control table reconfiguration failed");
    arm=0; repeat (2) @(negedge clk);
    // Reprogram while stopped: MOSI route source 3 is constant one.
    write_cfg(1, 16'h0c00); arm=1; repeat (5) @(negedge clk);
    if (mosi !== 1 || oe !== 3'b111) $fatal(1,"reconfigured route did not drive one");
    arm=0; write_cfg(0, 16'h0800); arm=1; repeat (2) @(negedge clk);
    if (oe !== 0) $fatal(1,"invalid configuration drove pins");
    arm=0; write_cfg(0, 16'h1108); arm=1; repeat (2) @(negedge clk);
    if (oe !== 0) $fatal(1,"unsupported width drove pins");
    $display("PASS: SPI timing, data, disarm and invalid configuration");
    $finish;
  end
endmodule
`default_nettype wire
