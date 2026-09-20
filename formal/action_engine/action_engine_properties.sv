`default_nettype none

module action_engine_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  reg [3:0] cfg_step = 4'd0;
  (* anyconst *) reg [1:0] extra_passes;
  wire [2:0] wr_slot = (cfg_step < 4'd2 || cfg_step == 4'd6) ? 3'd0 : 3'd1;
  wire wr_lo = cfg_step == 4'd0 || cfg_step == 4'd2 || cfg_step == 4'd6;
  wire wr_hi = cfg_step == 4'd1 || cfg_step == 4'd3;
  wire [7:0] wr_data = cfg_step == 4'd1 ? 8'h1f :
                       cfg_step == 4'd3 ? 8'h90 :
                       cfg_step == 4'd6 ? 8'h01 : 8'h00;
  wire start = cfg_step == 4'd4;

  wire busy;
  wire table_ready;
  wire done_pulse;
  wire [15:0] result;
  wire crc_feed;
  wire [7:0] crc_byte;
  wire tx_pop;
  wire rx_push;
  wire [7:0] rx_data;
  wire drive_enable;
  wire [7:0] drive_out_value;
  wire [7:0] drive_out_mask;
  wire [7:0] drive_oe_value;
  wire [7:0] drive_oe_mask;
  wire [7:0] claim;
  wire manual_serial_out;
  wire [15:0] shift_parallel;

  action_engine dut (
      .clk(clk), .rst_n(rst_n), .enable(1'b1),
      .wr_lo(wr_lo), .wr_hi(wr_hi),
      .wr_lane_lo(1'b0), .wr_lane_hi(1'b0),
      .wr_slot(wr_slot), .wr_data(wr_data),
      .load_shift(1'b0), .load_shift_hi(1'b0), .load_tx(1'b0),
      .tx_data(8'b0), .tx_empty(1'b1), .tx_pop(tx_pop),
      .rx_full(1'b0), .rx_push(rx_push), .rx_data(rx_data),
      .tx_bits(5'd8), .tx_msb_first(1'b0), .shift_data(8'b0),
      .manual_load(1'b0), .manual_data(8'b0),
      .manual_shift(1'b0), .manual_serial_in(1'b0),
      .manual_serial_out(manual_serial_out),
      .shift_parallel(shift_parallel),
      .start(start), .start_slot(3'd0),
      .repeat_count({6'b0, extra_passes}),
      .pin_sampled(8'b0), .pin_timed(8'b0),
      .crc_busy(1'b0), .crc_feed(crc_feed), .crc_byte(crc_byte),
      .busy(busy), .table_ready(table_ready),
      .done_pulse(done_pulse), .result(result),
      .drive_enable(drive_enable),
      .drive_out_value(drive_out_value),
      .drive_out_mask(drive_out_mask),
      .drive_oe_value(drive_oe_value),
      .drive_oe_mask(drive_oe_mask), .claim(claim)
  );

  reg launched = 1'b0;
  reg finished = 1'b0;
  reg [3:0] elapsed = 4'd0;
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      cfg_step <= 4'd0;
      launched <= 1'b0;
      finished <= 1'b0;
      elapsed <= 4'd0;
    end else begin
      if (cfg_step != 4'd15)
        cfg_step <= cfg_step + 1'b1;
      if (start) begin
        assert(table_ready);
        launched <= 1'b1;
        elapsed <= 4'd0;
      end else if (launched && !finished)
        elapsed <= elapsed + 1'b1;

      // The pin is reserved for the whole region, even between repeat
      // passes. An attempted rewrite of slot 0 on cfg_step 6 must be ignored.
      if (busy) begin
        assert(claim == 8'h01);
        assert((drive_out_mask & ~claim) == 0);
      end
      if (done_pulse) begin
        assert(launched && !finished);
        assert(elapsed == ({2'b0, extra_passes} + 4'd1) * 4'd2);
        assert(claim == 8'b0);
        finished <= 1'b1;
      end
      if (launched && !finished && elapsed > 4'd8)
        assert(done_pulse);
      if (finished)
        assert(!done_pulse);

      cover(done_pulse && extra_passes == 2'd3);
      cover(busy && wr_lo);
    end
  end
  wire _unused = &{result, crc_feed, crc_byte, tx_pop, rx_push, rx_data,
                   drive_enable, drive_out_value, drive_oe_value,
                   drive_oe_mask, manual_serial_out, shift_parallel, 1'b0};
endmodule

`default_nettype wire
