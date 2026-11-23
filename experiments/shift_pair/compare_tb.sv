`timescale 1ns/1ps
// Standalone RTL-only experiment, not in COCOTB_TEST_MODULES.
module compare_tb;
  reg clk=0, reset_n=0;
  always #5 clk=~clk;
  reg [1:0] start=0, step=0, sample=0, msb_first=0, serial_in=0;
  reg [9:0] width=0;
  reg [31:0] tx=0;
  wire [1:0] out_a,out_b,out_c,busy_a,busy_b,busy_c,done_a,done_b,done_c;
  wire [31:0] rx_a,rx_b,rx_c;
  wire ok_a,ok_b,ok_c;
  pair_separate a(clk,reset_n,start,step,sample,msb_first,width,tx,serial_in,out_a,rx_a,busy_a,done_a,ok_a);
  pair_combined_shared b(clk,reset_n,start,step,sample,msb_first,width,tx,serial_in,out_b,rx_b,busy_b,done_b,ok_b);
  pair_combined_independent c(clk,reset_n,start,step,sample,msb_first,width,tx,serial_in,out_c,rx_c,busy_c,done_c,ok_c);
  task automatic clock_cycle;
    begin
      @(posedge clk); #1;
      if ({out_a,rx_a,busy_a,done_a} !== {out_c,rx_c,busy_c,done_c} || !ok_a || !ok_c)
        $fatal(1,"independent candidates differ");
      @(negedge clk);
    end
  endtask
  task automatic reset_all;
    begin
      reset_n=0;start=0;step=0;sample=0;clock_cycle();clock_cycle();reset_n=1;
    end
  endtask
  integer i,j, hold_cycles, done0, done1;
  reg [7:0] tdi=8'h5a,tms=8'h80,tdo=8'h3c;
  reg controller_scl_low=0, target_scl_low=0, target_sda_low=0;
  wire scl_line=!(controller_scl_low || target_scl_low);
  wire sda_line=out_a[0] && !target_sda_low;
  reg [8:0] expected_bits=9'b101001011;
  initial begin
    @(negedge clk); reset_all();
    // JTAG scan8: two independently valued outputs, shared start/shift,
    // sample TDO on a separate event. Check wire bits against source bytes.
    width={5'd8,5'd8}; tx={8'h00,tms,8'h00,tdi}; msb_first=0;
    start=2'b11;clock_cycle();start=0;
    if (!ok_b || busy_a!=2'b11 || busy_b!=2'b11) $fatal(1,"JTAG start");
    for (i=0;i<8;i=i+1) begin
      if (out_a !== {tms[i],tdi[i]} || out_b !== out_a) $fatal(1,"JTAG outputs bit=%0d",i);
      serial_in={1'b0,tdo[i]};sample=2'b01;clock_cycle();sample=0;
      step=2'b11;clock_cycle();step=0;
      if ({out_a,rx_a,busy_a,done_a} !== {out_b,rx_b,busy_b,done_b}) $fatal(1,"shared common-event mismatch bit=%0d",i);
    end
    if (rx_a[15:8]!==tdo || busy_a!=0 || done_a!=2'b11) $fatal(1,"JTAG capture/done");
    // I2C byte phase: only data lane starts (8 MSB-first bits and a released
    // ACK bit). Open drain: output zero drives low, one releases. Emulate a
    // target stretching SCL before bit 3; step must remain low while held.
    reset_all(); width={5'd0,5'd9}; tx={16'd0,16'ha580};msb_first=2'b01;
    controller_scl_low=1;target_scl_low=0;target_sda_low=0;
    start=2'b01; #1; if (ok_b) $fatal(1,"shared candidate accepted independent start");
    clock_cycle();start=0; hold_cycles=0;
    for (i=0;i<9;i=i+1) begin
      if (out_a[0]!==expected_bits[8-i]) $fatal(1,"I2C SDA bit=%0d",i);
      controller_scl_low=0;
      if (i==3) begin
        target_scl_low=1;
        for (j=0;j<4;j=j+1) begin
          step=2'b00;clock_cycle();hold_cycles=hold_cycles+1;
          if (scl_line || !busy_a[0] || out_a[0]!==expected_bits[8-i]) $fatal(1,"changed during stretch");
        end
        target_scl_low=0;
      end
      #1;if (!scl_line) $fatal(1,"clock did not release");
      // Open-drain ACK: the controller releases the line, target pulls low.
      if (i==8) begin
        if (!out_a[0]) $fatal(1,"controller did not release ACK");
        target_sda_low=1;#1;serial_in[0]=sda_line;sample=2'b01;clock_cycle();sample=0;target_sda_low=0;
      end
      controller_scl_low=1;step[0]=1;#1;if (ok_b) $fatal(1,"shared candidate accepted independent step");
      clock_cycle();step=0;
    end
    if (hold_cycles!=4 || busy_a!=0 || done_a!=2'b01 || rx_a[0]!==0) $fatal(1,"I2C completion/ACK");
    // Both lanes active with independent lengths and event rates. A shared
    // sequencer must reject this request; separate lanes finish independently.
    reset_all(); width={5'd6,5'd4};tx={16'h002d,16'h000b};msb_first=0;
    start=2'b11;#1;if (ok_b) $fatal(1,"shared candidate accepted different lengths");
    clock_cycle();start=0;done0=0;done1=0;
    for (i=0;i<12;i=i+1) begin
      step[0]=(i<4);step[1]=(i%2==0);
      clock_cycle();
      if (done_a[0]) done0=done0+1;
      if (done_a[1]) done1=done1+1;
    end
    step=0;
    if (busy_a!=0 || done0!=1 || done1!=1) $fatal(1,"independent completion");
    $display("PASS: shared-event JTAG equivalence; independent byte lane and clock-stretch gating; shared block rejects mismatched controls");
    $finish;
  end
endmodule
