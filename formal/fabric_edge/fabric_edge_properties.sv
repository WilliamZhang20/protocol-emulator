`default_nettype none

// Edge cell against a pin stream and a shadow configuration. The harness
// keeps its own copy of each pin's previous value (as the core's
// synchronizer does) and of the last configuration write, and the cell's
// pulse must be exactly: the configured pin changed in a configured
// direction this cycle, while the qualifying level (if any) has the
// configured value. Covers: a qualified rise, a qualified fall, both
// directions from one cell, and an edge masked by its qualifier.
module fabric_edge_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [11:0] cfg_data;
  (* anyseq *) reg [7:0]  pins;
  (* anyseq *) reg [31:0] levels;
  reg [7:0] pins_prev = 8'd0;
  wire pulse;

  fabric_edge dut (
      .clk(clk), .rst_n(rst_n), .cfg_we(cfg_we), .cfg_data(cfg_data),
      .pin_now(pins), .pin_prev(pins_prev), .levels(levels), .pulse(pulse)
  );

  reg [11:0] cfg_s = 12'd0;
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    pins_prev <= pins;
    if (!rst_n)
      cfg_s <= 12'd0;
    else if (cfg_we)
      cfg_s <= cfg_data;
  end

  wire [2:0] pin  = cfg_s[2:0];
  wire rose = pins[pin] && !pins_prev[pin];
  wire fell = !pins[pin] && pins_prev[pin];
  wire want_rise = cfg_s[3], want_fall = cfg_s[4];
  wire qualified = cfg_s[10];
  wire gate_ok = !qualified || (cfg_s[11] ? !levels[cfg_s[9:5]] : levels[cfg_s[9:5]]);
  wire expected = gate_ok && ((want_rise && rose) || (want_fall && fell));

  always @(*) begin
    if (rst_n) begin
      assert(pulse == expected);
      cover(pulse && qualified && rose && !want_fall);
      cover(pulse && qualified && fell && cfg_s[11]);
      cover(pulse && want_rise && want_fall && fell);
      cover(!pulse && qualified && want_rise && rose);
    end
  end
endmodule

`default_nettype wire
