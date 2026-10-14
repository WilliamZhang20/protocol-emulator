`default_nettype none

// Spatial fabric timer tile. A reload counter that, once started, ticks
// every reload+1 cycles (first tick after phase+1 cycles). In toggle mode the
// output flips on each tick and the tick is reported as a rise or fall event;
// in pulse mode the output stays at idle and every tick is a rise event.
//
// Registers (16-bit, written by the controller):
//   0 reload       period - 1
//   1 phase        first-interval - 1 after a start
//   2 ctl          [4:0] start_sel  [9:5] stop_sel  [10] idle level
//                  [11] pulse mode  [14:12] hold pin  [15] hold enable
//   3 cmd          [0] start now    [1] stop now (write-only strobes)
//
// Program reload/phase/ctl only while the tile is stopped and not starting
// in the same cycle; a start always loads the previously written phase.
//
// Hold (clock stretching): while the output is high and the selected pin
// still reads low, the counter freezes.
module fabric_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [31:0] events,
    input  wire [7:0]  pins,
    output wire        out,
    output wire        rise,
    output wire        fall,
    output wire        running
);
  reg [15:0] reload;
  reg [15:0] phase;
  reg [15:0] ctl;
  reg [15:0] count;
  reg        out_r;
  reg        run;

  wire [4:0] start_sel = ctl[4:0];
  wire [4:0] stop_sel  = ctl[9:5];
  wire       idle      = ctl[10];
  wire       pulse     = ctl[11];
  wire [2:0] hold_pin  = ctl[14:12];
  wire       hold_en   = ctl[15];

  wire cmd_start = cfg_we && cfg_addr == 2'd3 && cfg_data[0];
  wire cmd_stop  = cfg_we && cfg_addr == 2'd3 && cfg_data[1];
  wire stop_now  = events[stop_sel] || cmd_stop;
  wire start_now = !run && (events[start_sel] || cmd_start);
  wire hold      = hold_en && out_r && !pins[hold_pin];
  wire tick      = enable && run && !stop_now && !hold && count == 16'd0;

  assign out     = out_r;
  assign rise    = tick && (pulse || !out_r);
  assign fall    = tick && !pulse && out_r;
  assign running = run;

  always @(posedge clk) begin
    if (!rst_n) begin
      reload <= 16'd0;
      phase  <= 16'd0;
      ctl    <= 16'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        2'd0: reload <= cfg_data;
        2'd1: phase  <= cfg_data;
        2'd2: ctl    <= cfg_data;
        default: begin end
      endcase
    end
  end

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
