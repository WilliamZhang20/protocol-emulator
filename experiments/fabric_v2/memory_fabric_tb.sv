`timescale 1ns/1ps
// Standalone RTL-only test with functional SRAM macros. Observes wrapper ports.
module memory_fabric_tb;
  reg clk=0,rst_n=0,arm=0,cfg_we=0,bank_cfg_we=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0;
  reg [1:0] bank_routes=0,pin_in=2'b11;
  reg host_req=0,host_we=0,start=0;
  reg [9:0] host_addr=0,source_addr=0,dest_addr=0;
  reg [7:0] host_wdata=0;
  wire host_ready,host_rvalid,configured,done,error,active;
  wire [7:0] host_rdata;
  wire [2:0] pin_out,pin_oe;
  wire [1:0] shift_busy,shift_done;
  fabric_v2_memory #(.USE_MACRO(1)) dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,
    bank_cfg_we,bank_routes,host_req,host_we,host_addr,host_wdata,host_ready,host_rvalid,host_rdata,
    start,source_addr,dest_addr,pin_in,pin_out,pin_oe,shift_busy,shift_done,configured,done,error,active);
  always #5 clk=~clk;
  initial begin #500000; $fatal(1,"timeout"); end
  reg [4:0] routes[0:15];
  reg [15:0] image_words[0:25];
  string spi_image,uart_image;
  integer uart_period=16,uart_first=16,clock_count=0;
  always @(posedge clk) clock_count<=clock_count+1;
  reg overlap=0,seen0=0,seen1=0,seen_done=0;
  always @(posedge clk) if(arm) begin
    if(shift_busy==2'b11) overlap<=1;
    if(shift_done[0]) seen0<=1;
    if(shift_done[1]) seen1<=1;
    if(done) begin
      if(shift_busy!=0) $fatal(1,"transaction done before both lanes are idle");
      seen_done<=1;
    end
  end
  task automatic cfg(input [4:0] addr,input [15:0] value);
    begin @(negedge clk);cfg_addr=addr;cfg_data=value;cfg_we=1;@(negedge clk);cfg_we=0;end
  endtask
  task automatic banks(input [1:0] value);
    begin @(negedge clk);bank_routes=value;bank_cfg_we=1;@(negedge clk);bank_cfg_we=0;end
  endtask
  task automatic host_write(input [9:0] addr,input [7:0] value);
    begin
      @(negedge clk);host_addr=addr;host_wdata=value;host_we=1;host_req=1;
      do @(posedge clk); while(!host_ready);
      @(negedge clk);host_req=0;host_we=0;
    end
  endtask
  task automatic host_read(input [9:0] addr,input [7:0] expected);
    begin
      @(negedge clk);host_addr=addr;host_we=0;host_req=1;
      do @(posedge clk); while(!host_ready);
      #1;if(!host_rvalid || host_rdata!==expected) $fatal(1,"host read addr=%0d got=%h expected=%h",addr,host_rdata,expected);
      @(negedge clk);host_req=0;
    end
  endtask
  task automatic load_image(input bit uart);
    integer k;
    begin
      if ((!uart && spi_image!="") || (uart && uart_image!="")) begin
        if(uart) $readmemh(uart_image,image_words); else $readmemh(spi_image,image_words);
        for(k=0;k<26;k=k+1) cfg(5'(k),image_words[k]);
        if(uart) begin uart_period=int'(image_words[1]);uart_first=int'(image_words[0]);end
      end else begin
      for(k=0;k<16;k=k+1) routes[k]=0;
      routes[0]=2;routes[1]=15;routes[3]=23;routes[4]=19;
      routes[6]=2;routes[9]=4;routes[10]=23;routes[11]=10;routes[12]=10;routes[13]=5;
      if(uart) begin routes[7]=6;routes[8]=0;routes[14]=17;end
      else begin routes[7]=8;routes[8]=7;routes[14]=16;routes[15]=9;end
      cfg(0,uart ? 16 : 8);cfg(1,uart ? 16 : 8);cfg(2,6);cfg(3,16);
      cfg(4,uart ? 10 : 44);cfg(5,10);
      for(k=0;k<16;k=k+1) cfg(5'(6+k),{11'd0,routes[k]});
      // {reserved, RX shift, TX shift, RX lane, RX bytes, TX bytes}
      cfg(22,uart ? 16'h0235 : 16'h000a);
      cfg(23,uart ? 16'h0200 : 16'h0000);
      cfg(24,uart ? 0 : 24);cfg(25,uart ? 1 : 7);
      end
      if(!configured) $fatal(1,"image invalid");
    end
  endtask
  task automatic pulse_start;
    begin @(negedge clk);start=1;@(negedge clk);start=0;end
  endtask
  task automatic preload(input bit uart);
    begin
      arm=0;banks(2'b11);arm=1;host_write(100,uart ? 8'h53 : 8'h0a);
      if(!uart) host_write(101,8'h5c);
      @(negedge clk);arm=0;banks(2'b10);
    end
  endtask
  task automatic spi_run(input bit alternate);
    integer bitno;
    reg [11:0] expected;
    begin
      expected=12'ha5c;source_addr=100;dest_addr=200;pin_in=2'b11;arm=1;
      fork
        pulse_start();
        // A write to a live configuration must not change the active route.
        begin repeat(4) @(negedge clk);cfg(20,0);end
        begin for(bitno=0;bitno<12;bitno=bitno+1) begin
          @(posedge pin_out[1]);#1;if(pin_out[2]!==0 || pin_out[0] !== (alternate ? 1'b0 : expected[11-bitno])) $fatal(1,"SPI tx bit %0d",bitno);
        end end
        begin @(posedge done);end
      join
      if(error) $fatal(1,"SPI error");
      @(negedge clk);arm=0;banks(2'b11);arm=1;
      host_read(200,8'h0f);host_read(201,8'hff);
      @(negedge clk);arm=0;
    end
  endtask
  task automatic uart_run;
    integer bitno;
    reg [7:0] inbound,outbound;
    begin
      inbound=8'h3c;outbound=8'h53;source_addr=100;dest_addr=200;pin_in=2'b11;
      overlap=0;seen0=0;seen1=0;seen_done=0;arm=1;
      repeat(6) @(negedge clk);
      if(pin_out[0]!==1 || pin_oe!=3'b001) $fatal(1,"UART idle");
      fork
        pulse_start();
        begin
          @(negedge pin_out[0]); @(negedge clk);pin_in[1]=0;
          repeat(uart_period) @(negedge clk);
          for(bitno=0;bitno<8;bitno=bitno+1) begin
            pin_in[1]=inbound[bitno];repeat(uart_period) @(negedge clk);
          end
          pin_in[1]=1;repeat(uart_period) @(negedge clk);
        end
        begin : tx_check
          integer k,launch_cycle,first_cycle;
          @(negedge pin_out[0]);#1;launch_cycle=clock_count;
          fork
            begin
              @(posedge pin_out[0]);#1;first_cycle=clock_count;
              if(first_cycle-launch_cycle!=uart_first+1) $fatal(1,"UART first-bit timing %0d",first_cycle-launch_cycle);
              @(negedge pin_out[0]);#1;
              if(clock_count-first_cycle!=2*uart_period) $fatal(1,"UART repeat timing %0d",clock_count-first_cycle);
            end
            begin
          repeat(uart_period/2) @(posedge clk);#1;if(pin_out[0]!==0) $fatal(1,"UART start");
          for(k=0;k<8;k=k+1) begin repeat(uart_period) @(posedge clk);#1;if(pin_out[0]!==outbound[k]) $fatal(1,"UART tx %0d",k);end
          repeat(uart_period) @(posedge clk);#1;if(pin_out[0]!==1) $fatal(1,"UART stop");
            end
          join
        end
        // Host accesses bank 0 while the serial adapter uses bank 1.
        begin repeat(20) @(negedge clk);host_write(10,8'h69);host_read(10,8'h69);end
      join
      repeat(6) @(negedge clk);
      if(!overlap || !seen0 || !seen1 || !seen_done || error) $fatal(1,"UART overlap/completion failure");
      @(negedge clk);arm=0;banks(2'b11);arm=1;host_read(200,inbound);
      @(negedge clk);arm=0;#1;if(pin_oe!=0) $fatal(1,"disarm OE");
    end
  endtask
  initial begin
    if (!$value$plusargs("SPI_IMAGE=%s",spi_image)) spi_image="";
    if (!$value$plusargs("UART_IMAGE=%s",uart_image)) uart_image="";
    repeat(2) @(negedge clk);rst_n=1;
    load_image(0);
    cfg(21,31);arm=1;#1;if(configured || pin_oe!=0) $fatal(1,"invalid route accepted");arm=0;
    cfg(21,9);preload(0);
    // A two-byte source at the last bank address must fail without wrapping.
    source_addr=1023;dest_addr=200;arm=1;fork pulse_start(); begin @(posedge done);end join
    #1;if(!error || active) $fatal(1,"boundary request was not rejected");
    @(negedge clk);arm=0;
    spi_run(0);
    // Reconfigure an actual output route while disarmed and repeat using SRAM.
    cfg(20,0);preload(0);spi_run(1);
    load_image(1);preload(1);uart_run();
    $display("PASS: same reconfigurable fabric uses SRAM/host for 12-bit SPI and overlapping UART TX/RX");
    $finish;
  end
endmodule
