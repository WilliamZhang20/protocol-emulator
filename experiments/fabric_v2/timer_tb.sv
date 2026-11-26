`default_nettype none
// grid_timer tile test.
// 1. Mode 0 (hold) with no live writes is cycle-for-cycle the old
//    fabric_v2_timer under random stimulus, so every existing image keeps
//    its timing.
// 2. Count mode ticks after N input pulses.
// 3. Capture latches the clocks between pulses.
// 4. Resync moves the count to the phase, inside its limit.
// 5. A live write waits for the next reload (never cuts a period short).
module timer_tb;
  reg clk = 0, rst_n = 0;
  always #5 clk = !clk;
  reg arm = 0, cfg_we = 0, live_we = 0, start = 0, stop = 0, aux = 0;
  reg [15:0] first = 0, period = 0, live_first = 0, live_period = 0, mode = 0, phase = 0;
  wire tick, running, configured, level, rise, fall;
  wire [15:0] captured;
  wire o_tick, o_running, o_configured, o_level, o_rise, o_fall;
  grid_timer dut(clk, rst_n, arm, cfg_we, first, period, live_we, live_first, live_period,
    mode, phase, start, stop, aux, tick, running, configured, level, rise, fall, captured);
  fabric_v2_timer old(clk, rst_n, arm, cfg_we, first, period, start, stop, aux,
    o_tick, o_running, o_configured, o_level, o_rise, o_fall);
  integer errors = 0, i, n, last, t0;

  task automatic fail(input [8*64-1:0] what);
    begin errors = errors + 1; $display("FAIL %0s at %0t", what, $time); end
  endtask
  task automatic configure(input [15:0] f, input [15:0] p, input [15:0] m, input [15:0] ph);
    begin
      @(negedge clk); arm = 0; cfg_we = 1; first = f; period = p; mode = m; phase = ph;
      @(negedge clk); cfg_we = 0; arm = 1;
    end
  endtask
  task automatic pulse_start;
    begin @(negedge clk); start = 1; @(negedge clk); start = 0; end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1;

    // 1. Equivalence with the old timer in hold mode.
    for (i = 0; i < 20000; i = i + 1) begin
      @(negedge clk);
      arm = ($random % 64) != 0;
      cfg_we = !arm && ($random % 2);
      first = $random % 6; period = $random % 6;
      start = ($random % 8) == 0; stop = ($random % 32) == 0; aux = ($random % 4) == 0;
      mode = 0;
      #1;
      if ({tick, running, configured, level, rise, fall} !== {o_tick, o_running, o_configured, o_level, o_rise, o_fall})
        fail("mode 0 differs from fabric_v2_timer");
    end
    @(negedge clk); start = 0; stop = 0; aux = 0;

    // 2. Count mode: first tick after 3 pulses, then every 2.
    configure(3, 2, 16'd1, 0);
    pulse_start;
    n = 0;
    for (i = 0; i < 7; i = i + 1) begin
      repeat (4) @(negedge clk);
      aux = 1; @(negedge clk); aux = 0;
      #1; if (tick) n = n + 1;
      if (tick != (i == 2 || i == 4 || i == 6)) fail("count mode tick");
    end
    if (n != 3) fail("count mode tick count");

    // 3. Capture: pulses 37 clocks apart read back as 37.
    configure(5, 5, 16'd2, 0);
    for (i = 0; i < 3; i = i + 1) begin
      @(negedge clk); aux = 1; @(negedge clk); aux = 0;
      repeat (35) @(negedge clk);   // rising edges 37 clocks apart
    end
    @(negedge clk); aux = 1; @(negedge clk); aux = 0; #1;
    if (captured != 37) begin fail("capture period"); $display("  captured %0d", captured); end

    // 4. Resync with limit 3: remaining 50 jumps toward phase 10 by 3 only;
    //    unlimited jumps to the phase.
    configure(100, 100, {8'd3, 8'd3}, 16'd10);
    pulse_start;
    repeat (49) @(negedge clk); #1;
    last = dut.remaining;
    @(negedge clk); aux = 1; @(negedge clk); aux = 0; #1;
    if (dut.remaining != last - 1 - 3) begin fail("limited resync"); $display("  %0d -> %0d", last, dut.remaining); end
    configure(100, 100, 16'd3, 16'd10);
    pulse_start;
    repeat (20) @(negedge clk);
    aux = 1; @(negedge clk); aux = 0; #1;
    if (dut.remaining != 10) fail("unlimited resync");
    // The next tick lands 10 clocks after the edge.
    t0 = 0;
    while (!tick && t0 < 50) begin @(negedge clk); #1; t0 = t0 + 1; end
    if (t0 != 10) begin fail("tick after resync"); $display("  %0d clocks", t0); end

    // 5. Shadowed live write: a running 20-clock period finishes before the
    //    new 7-clock period applies.
    configure(20, 20, 16'd0, 0);
    pulse_start;
    repeat (5) @(negedge clk);
    live_we = 1; live_first = 7; live_period = 7; @(negedge clk); live_we = 0;
    t0 = 0;
    while (!tick && t0 < 50) begin @(negedge clk); #1; t0 = t0 + 1; end
    if (t0 != 14) begin fail("live write cut the period"); $display("  first tick after %0d", t0); end
    t0 = 0;
    @(negedge clk); #1;
    while (!tick && t0 < 50) begin @(negedge clk); #1; t0 = t0 + 1; end
    if (t0 != 6) begin fail("live period not applied"); $display("  next tick after %0d", t0 + 1); end

    // Reserved mode bits make the tile unconfigured.
    configure(5, 5, 16'h0004, 0); #1;
    if (configured) fail("reserved mode bits accepted");

    if (errors == 0) $display("grid_timer tile test: PASS");
    else $fatal(1, "grid_timer tile test: %0d FAIL", errors);
    $finish;
  end
endmodule
`default_nettype wire
