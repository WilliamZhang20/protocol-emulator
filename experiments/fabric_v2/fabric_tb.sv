`timescale 1ns/1ps
// Standalone RTL-only integration test. Configuration and pin behavior are
// observed at the fabric interface; this is not a gate-level cocotb test.
module fabric_tb;
  reg clk=0,rst_n=0,arm=0,cfg_we=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0,tx0=0,tx1=0;
  reg [1:0] trigger=0,pin_in=2'b11;
  wire [2:0] pin_out,pin_oe;
  wire [1:0] busy,done;
  wire [15:0] rx0,rx1;
  wire configured;
  fabric_v2 dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,trigger,pin_in,tx0,tx1,
                pin_out,pin_oe,rx0,rx1,busy,done,configured);
  always #5 clk=~clk;
  reg [4:0] route[0:15];
  integer i;
  reg saw_overlap=0,done0_seen=0,done1_seen=0;
  always @(posedge clk) if (arm) begin
    if (busy==2'b11) saw_overlap<=1;
    if (done[0]) done0_seen<=1;
    if (done[1]) done1_seen<=1;
  end
  initial begin #500000; $fatal(1,"timeout"); end
  task automatic writecfg(input [4:0] addr,input [15:0] data);
    begin @(negedge clk);cfg_we=1;cfg_addr=addr;cfg_data=data;@(negedge clk);cfg_we=0;end
  endtask
  task automatic image(input bit uart,input bit alternate);
    integer k;
    begin
      for(k=0;k<16;k=k+1) route[k]=0;
      route[0]=2;route[1]=15; // timer0: trigger0 until shift0 done
      route[3]=23;route[4]=19; // timer1: pin1 falling until shift1 done
      route[6]=2;route[9]=4; // lane0: trigger0, input pin0
      route[10]=23;route[11]=10;route[12]=10;route[13]=5; // RX lane1
      if (uart) begin route[7]=6;route[8]=0;route[14]=17;route[15]=0;end
      else begin route[7]=8;route[8]=7;route[14]=alternate ? 0 : 16;route[15]=9;end
      writecfg(0,uart ? 16 : 8);writecfg(1,uart ? 16 : 8);
      writecfg(2,6);writecfg(3,16);
      writecfg(4,uart ? 10 : (32+12));writecfg(5,10);
      for(k=0;k<16;k=k+1) writecfg(5'(6+k),{11'd0,route[k]});
      writecfg(24,uart ? 0 : 24);writecfg(25,uart ? 1 : 7);
      if (!configured) $fatal(1,"image rejected");
    end
  endtask
  task automatic pulse_trigger;
    begin @(negedge clk);trigger[0]=1;@(negedge clk);trigger[0]=0;end
  endtask
  task automatic spi_transfer(input bit alternate);
    integer bitno;
    begin
      pin_in=2'b11;tx0=16'h0a5c; arm=1;
      repeat(4) @(negedge clk);
      if(pin_oe!=3'b111 || pin_out[2]!==1) $fatal(1,"outputs not armed or CS not idle");
      fork
        pulse_trigger();
        begin
          for(bitno=0;bitno<12;bitno=bitno+1) begin
            @(posedge pin_out[1]); #1;
            if (pin_out[2]!==0 || pin_out[0] !== (alternate ? 1'b0 : tx0[11-bitno])) $fatal(1,"SPI output bit=%0d",bitno);
          end
        end
        begin @(posedge done[0]); end
      join
      #1;if(rx0!==16'h0fff) $fatal(1,"SPI rx %h",rx0);
      @(negedge clk);arm=0;#1;if(pin_oe!=0) $fatal(1,"SPI disarm");
    end
  endtask
  task automatic uart_test;
    integer bitno;
    reg [7:0] in_byte,out_byte;
    begin
      in_byte=8'h3c;out_byte=8'h53;tx0={6'd0,1'b1,out_byte,1'b0};
      pin_in=2'b11;arm=1;saw_overlap=0;done0_seen=0;done1_seen=0;
      repeat(6) @(negedge clk);
      if(pin_out[0]!==1'b1 || pin_oe!=3'b001) $fatal(1,"UART idle");
      fork
        begin
          @(negedge clk);trigger[0]=1;pin_in[1]=0;
          @(negedge clk);trigger[0]=0;
          repeat(15) @(negedge clk);
          for(bitno=0;bitno<8;bitno=bitno+1) begin
            pin_in[1]=in_byte[bitno];repeat(16) @(negedge clk);
          end
          pin_in[1]=1;repeat(16) @(negedge clk);
        end
        begin : tx_check
          integer k;
          @(negedge pin_out[0]);
          repeat(8) @(posedge clk); #1;if(pin_out[0]!==0) $fatal(1,"UART start");
          for(k=0;k<8;k=k+1) begin
            repeat(16) @(posedge clk); #1;if(pin_out[0]!==out_byte[k]) $fatal(1,"UART tx bit %0d",k);
          end
          repeat(16) @(posedge clk);#1;if(pin_out[0]!==1) $fatal(1,"UART stop");
        end
      join
      repeat(8) @(negedge clk);
      if (!saw_overlap || !done0_seen || !done1_seen) $fatal(1,"UART did not overlap/complete");
      if (rx1[9:0]!=={1'b1,in_byte,1'b0}) $fatal(1,"UART rx %h",rx1);
      arm=0;#1;if(pin_oe!=0) $fatal(1,"UART disarm");
    end
  endtask
  initial begin
    repeat(2) @(negedge clk);rst_n=1;
    // Incomplete and invalid image must not drive pins.
    arm=1;#1;if(configured || pin_oe!=0) $fatal(1,"incomplete image accepted");arm=0;
    image(0,0);spi_transfer(0);
    image(0,1);spi_transfer(1);
    image(1,0);
    writecfg(21,31);arm=1;#1;if(configured || pin_oe!=0) $fatal(1,"invalid route accepted");arm=0;
    writecfg(21,0);uart_test();
    $display("PASS: one configurable fabric runs 12-bit SPI, reroutes output, then overlaps UART TX/RX");
    $finish;
  end
endmodule
