`timescale 1ns/1ps
`default_nettype none
// Drives the standalone tile slice entirely through its configuration,
// payload and pin ports. The image is produced by the CIRCT experiment.
module circt_image_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0, trigger=0, host_we=0, miso=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0, host_wdata=0;
  reg [1:0] host_addr=0;
  wire [15:0] host_rdata, rx_word;
  wire host_rvalid, cs, sck, mosi, done;
  wire [2:0] oe;
  spi_fabric dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,
                 host_we,host_addr,host_wdata,host_rdata,host_rvalid,
                 miso,cs,sck,mosi,oe,done,rx_word);

  reg [15:0] image[0:18];
  reg [1023:0] image_path;
  reg [15:0] reply=16'h5a30, observed=0, expected_tx, expected_rx;
  reg old_sck=0, old_mosi=0;
  integer width=0, half_period=0, samples=0, edges=0, tick=0, last_edge=-1;
  integer i, cycles=0;
  always @(negedge clk) begin
    tick=tick+1;
    if (arm && oe==3'b111 && !cs) begin
      if (sck != old_sck) begin
        if (last_edge>=0 && tick-last_edge!=half_period) $fatal(1,"clock period");
        last_edge=tick; edges=edges+1;
      end
      if (!old_sck && sck) begin
        if (mosi !== old_mosi) $fatal(1,"MOSI setup");
        observed={observed[14:0],mosi}; samples=samples+1;
      end
      if (old_sck && !sck && samples<width) miso=reply[15-samples];
    end
    old_sck=sck; old_mosi=mosi;
  end

  initial begin
    if (!$value$plusargs("IMAGE=%s",image_path)) $fatal(1,"IMAGE required");
    $readmemh(image_path,image);
    width={27'd0,image[0][12:8]}; half_period={24'd0,image[0][7:0]};
    if (width<1 || width>16) $fatal(1,"image width");
    expected_tx=image[18] >> (16-width); expected_rx=reply >> (16-width);
    repeat (3) @(negedge clk); rst_n=1;
    for (i=0; i<18; i=i+1) begin
      @(negedge clk); cfg_we=1; cfg_addr=i[4:0]; cfg_data=image[i];
      @(negedge clk); cfg_we=0;
    end
    @(negedge clk); host_addr=0; host_wdata=image[18]; host_we=1;
    @(negedge clk); host_we=0;
    @(negedge clk); arm=1; miso=reply[15];
    repeat (5) @(negedge clk);
    if (oe!==3'b111 || cs!==1 || sck!==0) $fatal(1,"idle");
    trigger=1; @(negedge clk); trigger=0;
    while (!done && cycles<600) begin @(negedge clk); cycles=cycles+1; end
    repeat (3) @(negedge clk); host_addr=1; #1;
    if (!done || cs!==1 || sck!==0 || samples!=width || edges!=2*width ||
        observed!==expected_tx || !host_rvalid || host_rdata!==expected_rx)
      $fatal(1,"image transaction: width=%0d samples=%0d edges=%0d tx=%h/%h rx=%h/%h",
             width,samples,edges,observed,expected_tx,host_rdata,expected_rx);
    $display("PASS image: width=%0d tx=%h rx=%h cycles=%0d",width,observed,host_rdata,cycles);
    $finish;
  end
endmodule
`default_nettype wire
