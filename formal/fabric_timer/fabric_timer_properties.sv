`default_nettype none

// Timer tile against an independent cycle-count reference: after a start or
// resync the next tick lands exactly phase+1 cycles later and then every
// reload+1 cycles, hold freezes time, stop wins over everything, and the
// output only moves on a tick (or returns to idle while stopped).
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
  (* anyseq *) reg [63:0] lines_any;
  wire [63:0] lines = {lines_any[63:2], 1'b1, 1'b0};
  wire out, rise, fall;

  fabric_timer dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .lines(lines), .out(out), .rise(rise), .fall(fall)
  );

  // Shadow configuration, programmed only while stopped and not starting.
  reg [15:0] reload_s = 16'd0, phase_s = 16'd0;
  reg [13:0] ctl_s = 14'd0;
  reg [12:0] sync_s = 13'd0;
  wire stop   = lines[ctl_s[11:6]];
  wire start  = lines[ctl_s[5:0]];
  wire [31:0] levels = lines[63:32];
  wire resync = sync_s[5] && levels[sync_s[4:0]];
  wire hold   = out && sync_s[11] && (levels[sync_s[10:6]] ^ sync_s[12]);

  reg        r_run = 1'b0;
  reg        r_first = 1'b0;
  reg [16:0] r_since = 17'd0;
  wire [16:0] r_target = {1'b0, r_first ? phase_s : reload_s};
  wire expect_tick = enable && r_run && !stop && !resync && !hold &&
                     r_since == r_target;
  always @(*) if (rst_n && cfg_we) assume(!r_run && !start);

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      reload_s <= 16'd0; phase_s <= 16'd0; ctl_s <= 14'd0; sync_s <= 13'd0;
      r_run <= 1'b0; r_first <= 1'b0; r_since <= 17'd0;
    end else begin
      if (cfg_we) begin
        case (cfg_addr)
          2'd0: reload_s <= cfg_data;
          2'd1: phase_s  <= cfg_data;
          2'd2: ctl_s    <= cfg_data[13:0];
          default: sync_s <= cfg_data[12:0];
        endcase
      end
      if (!enable || stop) begin
        r_run <= 1'b0;
      end else if (!r_run && start) begin
        r_run <= 1'b1; r_first <= 1'b1; r_since <= 17'd0;
      end else if (r_run && resync) begin
        r_first <= 1'b1; r_since <= 17'd0;
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
    past_halt   <= stop || !r_run;
    past_tick   <= rise || fall;
    past_out    <= out;
    past_pulse  <= ctl_s[13];
    past_idle   <= ctl_s[12];
  end

  always @(*) begin
    if (rst_n) begin
      assert((rise || fall) == expect_tick);
      assert(!(rise && fall));
      if (r_run) assert(r_since <= r_target);
      if (rise || fall) assert(rise == (ctl_s[13] || !out));
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
      cover(fall && sync_s[12]);
      cover(rise && r_first && phase_s == 16'd2 && reload_s == 16'd5);
    end
  end
endmodule

`default_nettype wire
