`timescale 1ns/1ps
// Standalone RTL-only timing probe. Not part of COCOTB_TEST_MODULES or GL.
module route_latency_probe_tb;
  reg clk=0, rst_n=0, tick=0, pad=0;
  always #5 clk=~clk;
  wire p1,p2,p3,sync_in,stretch_route;
  reg consumed=0, hold_observed=0;
  proto_route r1(clk,rst_n,2'b00,{3'b0,tick},p1);
  proto_route r2(clk,rst_n,2'b00,{3'b0,p1},p2);
  proto_route r3(clk,rst_n,2'b00,{3'b0,p2},p3);
  proto_pin_in inpin(clk,rst_n,pad,sync_in);
  proto_route hold_route(clk,rst_n,2'b00,{3'b0,sync_in},stretch_route);
  always @(posedge clk) begin
    if (!rst_n) begin consumed<=0; hold_observed<=0; end
    else begin consumed<=p3; hold_observed<=stretch_route; end
  end
  integer cycle, first_hold=-1, event_count=0, last_event=-1;
  reg [3:0] history=0;
  initial begin
    repeat (2) @(negedge clk);
    rst_n=1;
    for (cycle=0;cycle<16;cycle=cycle+1) begin
      tick=(cycle<12 && cycle%2==0);
      pad=1;
      @(posedge clk); #1;
      if (p1!==tick || p2!==history[0] || p3!==history[1] || consumed!==history[2])
        $fatal(1,"route mismatch cycle=%0d",cycle);
      if (consumed) begin
        if (last_event>=0 && cycle-last_event!=2) $fatal(1,"event spacing changed");
        last_event=cycle;event_count=event_count+1;
      end
      if (hold_observed && first_hold<0) first_hold=cycle;
      history={history[2:0],tick};
      @(negedge clk);
    end
    if (event_count!=6 || first_hold!=3) $fatal(1,"events=%0d first_hold=%0d",event_count,first_hold);
    $display("PASS: three registered routes preserve 2-cycle event spacing; 2-flop input plus route reaches consumer on edge 3");
    $finish;
  end
endmodule
