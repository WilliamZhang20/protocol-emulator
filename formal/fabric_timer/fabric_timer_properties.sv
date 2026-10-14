`default_nettype none

// Timer tile against an independent cycle-count reference: after a start the
// first tick lands exactly phase+1 cycles later and then every reload+1
// cycles, hold freezes time, stop wins over everything, and the output only
// moves on a tick (or returns to idle while stopped).
module fabric_timer_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [1:0]  cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [31:0] events_any;
  (* anyseq *) reg [7:0]  pins;
  wire [31:0] events = {events_any[31:2], 1'b1, 1'b0};
  wire out, rise, fall, running;

  fabric_timer dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .events(events), .pins(pins),
      .out(out), .rise(rise), .fall(fall), .running(running)
  );

  // Shadow configuration. Period registers only change while stopped, which
  // is how the controller programs a tile.
  reg [15:0] reload_s = 16'd0, phase_s = 16'd0, ctl_s = 16'd0;
  wire write_cfg = cfg_we && cfg_addr != 2'd3;

  wire cmd_start = cfg_we && cfg_addr == 2'd3 && cfg_data[0];
  wire cmd_stop  = cfg_we && cfg_addr == 2'd3 && cfg_data[1];
  wire stop  = events[ctl_s[9:5]] || cmd_stop;
  wire start = events[ctl_s[4:0]] || cmd_start;
  wire hold  = ctl_s[15] && out && !pins[ctl_s[14:12]];
  always @(*) if (rst_n && write_cfg) assume(!r_run && !start);

  reg        r_run = 1'b0;
  reg        r_first = 1'b0;
  reg [16:0] r_since = 17'd0;
  wire [16:0] r_target = {1'b0, r_first ? phase_s : reload_s};
  wire expect_tick = enable && r_run && !stop && !hold && r_since == r_target;

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      reload_s <= 16'd0; phase_s <= 16'd0; ctl_s <= 16'd0;
      r_run <= 1'b0; r_first <= 1'b0; r_since <= 17'd0;
    end else begin
      if (write_cfg) begin
        case (cfg_addr)
          2'd0: reload_s <= cfg_data;
          2'd1: phase_s  <= cfg_data;
          default: ctl_s <= cfg_data;
        endcase
      end
      if (!enable || stop) begin
        r_run <= 1'b0;
      end else if (!r_run && start) begin
        r_run <= 1'b1; r_first <= 1'b1; r_since <= 17'd0;
      end else if (r_run && !hold) begin
        if (r_since == r_target) begin
          r_first <= 1'b0; r_since <= 17'd0;
        end else
          r_since <= r_since + 17'd1;
      end
    end
  end

  reg past_valid = 1'b0;
  reg past_enable, past_halt, past_tick, past_out, past_pulse, past_idle;
  always @(posedge clk) begin
    past_valid  <= rst_n;
    past_enable <= enable;
    past_halt   <= stop || !running;
    past_tick   <= rise || fall;
    past_out    <= out;
    past_pulse  <= ctl_s[11];
    past_idle   <= ctl_s[10];
  end

  always @(*) begin
    if (rst_n) begin
      assert(running == r_run);
      assert((rise || fall) == expect_tick);
      assert(!(rise && fall));
      if (r_run) assert(r_since <= r_target);
      if (rise || fall) assert(rise == (ctl_s[11] || !out));
    end
  end

  // The output only moves on a toggle-mode tick, or returns to idle while
  // stopped (including the start cycle), or to 0 while disabled.
  always @(posedge clk) begin
    if (rst_n && past_valid) begin
      if (!past_enable) assert(out == 1'b0);
      else if (past_halt) assert(out == past_idle);
      else if (past_tick && !past_pulse) assert(out == !past_out);
      else assert(out == past_out);
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover(rise && !r_first && reload_s == 16'd3);
      cover(fall && ctl_s[15]);
    end
  end
endmodule

`default_nettype wire
