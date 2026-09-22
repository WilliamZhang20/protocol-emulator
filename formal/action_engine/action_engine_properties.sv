`default_nettype none

module action_engine_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  reg [3:0] cfg_step = 4'd0;
  (* anyconst *) reg [1:0] extra_passes;
  wire [3:0] wr_slot = (cfg_step < 4'd2 || cfg_step == 4'd6) ? 4'd0 : 4'd1;
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
  wire tx_request;
  wire rx_request;
  wire [7:0] rx_data;
  wire drive_enable;
  wire [7:0] drive_out_value;
  wire [7:0] drive_out_mask;
  wire [7:0] drive_oe_value;
  wire [7:0] drive_oe_mask;
  wire [7:0] claim;
  wire [15:0] lfsr_value;
  wire [7:0] launch_claim;

  action_lane dut (
      .clk(clk), .rst_n(rst_n), .enable(1'b1),
      .wr_lo(wr_lo), .wr_hi(wr_hi),
      .wr_bundle_lo(1'b0), .wr_bundle_hi(1'b0),
      .wr_slot(wr_slot), .wr_data(wr_data),
      .load_shift_lo(1'b0), .load_shift_hi(1'b0), .load_tx(1'b0),
      .load_data(8'b0), .load_bits(5'd8), .load_msb_first(1'b0),
      .start(start), .start_slot(4'd0),
      .repeat_count({6'b0, extra_passes}),
      .pin_sampled(8'b0), .pin_timed(8'b0),
      .tx_request(tx_request), .tx_grant(1'b0), .tx_data(8'b0),
      .rx_request(rx_request), .rx_grant(1'b0), .rx_data(rx_data),
      .busy(busy), .table_ready(table_ready), .done_pulse(done_pulse),
      .result(result), .lfsr_value(lfsr_value),
      .launch_claim(launch_claim),
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
  wire _unused = &{result, tx_request, rx_request, rx_data,
                   drive_enable, drive_out_value, drive_oe_value,
                   drive_oe_mask, launch_claim, lfsr_value, 1'b0};
endmodule

`default_nettype wire
