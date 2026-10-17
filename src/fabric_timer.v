`default_nettype none

// Spatial fabric timer tile. A reload counter that, once started, ticks
// every reload+1 cycles (first tick after phase+1 cycles). In toggle mode the
// output flips on each tick and the tick is reported as a rise or fall event;
// in pulse mode the output stays at idle and every tick is a rise event.
//
// Registers (16-bit, written by the controller):
//   0 reload  period - 1
//   1 phase   first interval - 1 after a start or resync
//   2 ctl     [5:0] start line  [11:6] stop line  [12] idle level
//             [13] pulse mode
//   3 sync    [4:0] resync level  [5] resync enable
//             [10:6] hold level   [11] hold enable  [12] hold invert
//
// Start/stop select any of the 64 lines; resync and hold select one of the
// 32 level lines (signal space 32-63). Priority per cycle:
// stop, start (only while stopped), resync (restart the interval at phase,
// for clock recovery), hold (freeze while the output is high and the hold
// line, optionally inverted, is high: clock stretching), then count.
// Program reload/phase/ctl only while the tile is stopped and not starting
// in the same cycle; a start always loads the previously written phase.
module fabric_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [1:0]  cfg_bank,      // contexts a write goes to
    input  wire        ctx,       // active context
    input  wire [63:0] lines,
    output wire        out,
    output wire        rise,
    output wire        fall
);
  wire [15:0] reload, phase;
  wire [13:0] ctl;
  wire [12:0] sync;
  reg  [15:0] count;
  reg        out_r;
  reg        run;

  wire idle  = ctl[12];
  wire pulse = ctl[13];

  wire [31:0] levels = lines[63:32];
  wire stop_now   = lines[ctl[11:6]];
  wire start_now  = !run && lines[ctl[5:0]];
  wire resync_now = run && sync[5] && levels[sync[4:0]];
  wire hold       = out_r && sync[11] && (levels[sync[10:6]] ^ sync[12]);
  wire tick = enable && run && !stop_now && !resync_now && !hold &&
              count == 16'd0;

  assign out  = out_r;
  assign rise = tick && (pulse || !out_r);
  assign fall = tick && !pulse && out_r;

  config_bank #(.WIDTH(16)) reload_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd0), .write_bank(cfg_bank), .data(cfg_data),
      .ctx(ctx), .ctx_next(ctx), .value(reload), .next());
  config_bank #(.WIDTH(16)) phase_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd1), .write_bank(cfg_bank), .data(cfg_data),
      .ctx(ctx), .ctx_next(ctx), .value(phase), .next());
  config_bank #(.WIDTH(14)) ctl_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd2), .write_bank(cfg_bank), .data(cfg_data[13:0]),
      .ctx(ctx), .ctx_next(ctx), .value(ctl), .next());
  config_bank #(.WIDTH(13)) sync_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd3), .write_bank(cfg_bank), .data(cfg_data[12:0]),
      .ctx(ctx), .ctx_next(ctx), .value(sync), .next());

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      count <= 16'd0;
      out_r <= 1'b0;
      run   <= 1'b0;
    end else if (stop_now) begin
      run   <= 1'b0;
      out_r <= idle;
    end else if (start_now) begin
      run   <= 1'b1;
      count <= phase;
      out_r <= idle;
    end else if (!run) begin
      out_r <= idle;
    end else if (resync_now) begin
      count <= phase;
    end else if (!hold) begin
      if (count == 16'd0) begin
        count <= reload;
        if (!pulse)
          out_r <= !out_r;
      end else
        count <= count - 16'd1;
    end
  end
endmodule

`default_nettype wire
