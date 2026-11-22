`timescale 1ns/1ps
`default_nettype none
module spi_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, trigger=0, miso=0, cfg_we=0, cfg_addr=0;
  reg [15:0] cfg_data=0;
  reg [7:0] half_period=8, tx_word=8'ha5;
  reg [3:0] width=8;
  wire cs, sck, mosi, done;
  wire [2:0] oe;
  wire [7:0] rx_word;
  spi_fabric dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,tx_word,miso,
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

  task write_cfg(input reg address, input [15:0] data);
    begin
      @(negedge clk); cfg_we=1; cfg_addr=address; cfg_data=data;
      @(negedge clk); cfg_we=0;
    end
  endtask

  // Pin-level mode-0 peripheral: preload reply bit 7, sample MOSI on rising
  // edges, and update the next MISO bit on falling edges. No DUT hierarchy.
  integer bit_index=0, cycles=0, tick=0, last_edge=-1, edge_count=0;
  reg [7:0] observed=0;
  reg [7:0] reply=8'h5a;
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
        observed = {observed[6:0], mosi};
        bit_index = bit_index + 1;
      end
      if (old_sck && !sck && bit_index < {28'd0, width})
        miso = reply[7-bit_index];
    end
    old_sck = sck;
    old_mosi = mosi;
  end

  initial begin
    repeat (3) @(negedge clk); rst_n=1;
    // A partial image cannot arm; both words must be written while disarmed.
    write_cfg(0, 16'h0808);
    @(negedge clk); arm=1; repeat (3) @(negedge clk);
    if (oe !== 0) $fatal(1,"incomplete configuration drove pins");
    arm=0; write_cfg(1, 16'h0000);
    @(negedge clk); arm=1; miso=0;
    repeat (5) @(negedge clk);
    if (oe !== 3'b111 || cs !== 1 || sck !== 0) $fatal(1,"bad idle");
    // This attempted MOSI reroute must be ignored while armed.
    write_cfg(1, 16'h0c00);
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles < 400) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0 || bit_index != 8 || edge_count != 16 || observed !== 8'ha5 || rx_word !== 8'h5a)
      $fatal(1,"SPI failed: done=%b cs=%b sck=%b samples=%0d edges=%0d tx=%h rx=%h",done,cs,sck,bit_index,edge_count,observed,rx_word);
    if (!route_tests_done) $fatal(1,"route matrix test incomplete");
    $display("SPI exchange: tx=%h rx=%h, %0d cycles",observed,rx_word,cycles);
    arm=0; repeat (2) @(negedge clk);
    if (oe !== 0) $fatal(1,"disarm did not release pins");
    // Same physical tiles/routes, different width: five MSB-first bits.
    bit_index=0; edge_count=0; last_edge=-1; observed=0; cycles=0;
    width=5; tx_word=8'ha8; miso=0;
    write_cfg(0, 16'h0508); arm=1; repeat (5) @(negedge clk);
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles < 400) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk);
    if (!done || cs !== 1 || sck !== 0 || bit_index != 5 || edge_count != 10 || observed !== 8'h15 || rx_word !== 8'h0b)
      $fatal(1,"5-bit SPI failed: samples=%0d edges=%0d tx=%h rx=%h",bit_index,edge_count,observed,rx_word);
    $display("5-bit exchange: tx=%h rx=%h, %0d cycles",observed,rx_word,cycles);
    arm=0; repeat (2) @(negedge clk);
    // Reprogram while stopped: MOSI route source 3 is constant one.
    write_cfg(1, 16'h0c00); arm=1; repeat (5) @(negedge clk);
    if (mosi !== 1 || oe !== 3'b111) $fatal(1,"reconfigured route did not drive one");
    arm=0; write_cfg(0, 16'h0800); arm=1; repeat (2) @(negedge clk);
    if (oe !== 0) $fatal(1,"invalid configuration drove pins");
    $display("PASS: SPI timing, data, disarm and invalid configuration");
    $finish;
  end
endmodule
`default_nettype wire
