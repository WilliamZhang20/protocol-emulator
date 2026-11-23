`timescale 1ns/1ps
`default_nettype none
module memory_spi_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,arm=0,cfg_we=0,bank_cfg_we=0,trigger=0,host_req=0,host_we=0,miso=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0;
  reg [1:0] bank_routes=0;
  reg [9:0] host_addr=0;
  reg [7:0] host_wdata=0;
  wire host_ready,host_valid,cs,sck,mosi,done,error,active;
  wire [7:0] host_data;
  wire [2:0] oe;
  reg [15:0] image[0:18];
  reg [1023:0] path;
  integer i,samples=0,edges=0,tick=0,last_edge=-1,expected_half=0,cycles=0, memory_steps=0;
  reg old_sck=0,old_mosi=0;
  reg [15:0] observed=0;
  memory_spi_fabric #(.USE_MACRO(1)) dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,
      bank_cfg_we,bank_routes,trigger,10'd100,10'd200,host_req,host_we,host_addr,
      host_wdata,host_ready,host_valid,host_data,miso,cs,sck,mosi,oe,done,error,active);
  // RTL-only observation: check the source graph's memory-request sequence.
  // This standalone bench is not in COCOTB_TEST_MODULES or the gate test.
  always @(posedge clk) if (rst_n && arm && dut.req && dut.ready[1]) begin
    case (memory_steps % 4)
      0: if (dut.we || dut.addr!=100) $fatal(1,"expected read of byte 100");
      1: if (dut.we || dut.addr!=101) $fatal(1,"expected read of byte 101");
      2: if (!dut.we || dut.addr!=200 || dut.wdata!=8'h0f) $fatal(1,"expected high-byte write");
      3: if (!dut.we || dut.addr!=201 || dut.wdata!=8'hff) $fatal(1,"expected low-byte write");
    endcase
    memory_steps=memory_steps+1;
  end
  always @(negedge clk) begin
    tick=tick+1;
    if (oe[0] && !active && !cs) $fatal(1,"CS asserted while fabric idle");
    if (oe==3'b111 && !cs && sck!=old_sck) begin
      if (last_edge>=0 && tick-last_edge!=expected_half) $fatal(1,"clock interval %0d expected %0d",tick-last_edge,expected_half);
      last_edge=tick; edges=edges+1;
      if (sck) begin
        if (mosi!==old_mosi) $fatal(1,"serial setup");
        observed={observed[14:0],mosi}; samples=samples+1;
      end
    end
    old_sck=sck; old_mosi=mosi;
  end
  task write_byte(input [9:0] a,input [7:0] d);
    begin
      @(negedge clk); host_addr=a;host_wdata=d;host_we=1;host_req=1;
      do @(posedge clk); while (!host_ready);
      @(negedge clk); host_req=0;host_we=0;
    end
  endtask
  task read_byte(input [9:0] a,input [7:0] d);
    begin
      @(negedge clk); host_addr=a;host_we=0;host_req=1;
      do @(posedge clk); while (!host_ready);
      #1; if (!host_valid || host_data!==d) $fatal(1,"read %0d: %h expected %h",a,host_data,d);
      @(negedge clk); host_req=0;
    end
  endtask
  task configure(input [15:0] route_word);
    begin
      for (i=0;i<18;i=i+1) begin
        @(negedge clk);cfg_we=1;cfg_addr=i[4:0];cfg_data=i==1 ? route_word : image[i];
        @(negedge clk);cfg_we=0;
      end
    end
  endtask
  task transfer(input [15:0] want);
    begin
      samples=0;edges=0;observed=0;last_edge=-1;cycles=0;
      @(negedge clk);trigger=1;@(negedge clk);trigger=0;
      while (!done && cycles<500) begin @(negedge clk);cycles=cycles+1;end
      if (!done || error || samples!=12 || edges!=24 || observed!==want)
        $fatal(1,"transfer samples=%0d edges=%0d tx=%h expected=%h error=%b",samples,edges,observed,want,error);
      read_byte(200,8'h0f);read_byte(201,8'hff);
    end
  endtask
  initial begin
    if (!$value$plusargs("IMAGE=%s",path)) $fatal(1,"IMAGE required");
    $readmemh(path,image); expected_half={24'd0,image[0][7:0]};
    if (image[0][12:8]!=12 || image[18]!==16'ha5c0) $fatal(1,"unexpected source image");
    repeat(3) @(negedge clk);rst_n=1;
    bank_cfg_we=1;bank_routes=2'b11;@(negedge clk);bank_cfg_we=0;
    // Incomplete configuration must leave output pins disabled.
    @(negedge clk);cfg_we=1;cfg_addr=0;cfg_data=image[0];
    @(negedge clk);cfg_we=0;arm=1;repeat(3) @(negedge clk);
    if (oe!==0) $fatal(1,"incomplete image enabled pins");
    arm=0;configure(image[1]);@(negedge clk);arm=1;miso=1;
    repeat(6) @(negedge clk);if (oe!==7 || !cs || sck) $fatal(1,"bad idle");
    write_byte(100,8'h0a);write_byte(101,8'h5c);
    transfer(16'h0a5c);
    // Route MOSI to constant zero, with the same configured controller and SRAM.
    @(negedge clk);arm=0;repeat(3) @(negedge clk);
    configure(image[1] | 16'h0800);@(negedge clk);arm=1;repeat(6) @(negedge clk);
    transfer(16'h0000);
    if (memory_steps!=8) $fatal(1,"expected four SRAM operations per transfer");
    $display("PASS: source-derived SPI component with two SRAM banks and reconfigured signal routes");
    $finish;
  end
endmodule
`default_nettype wire
