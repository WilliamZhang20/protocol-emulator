`default_nettype none

module action_stream_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;

  reg [1:0] reset_cycles = 0;
  wire rst_n = reset_cycles >= 2;
  reg [4:0] cfg_step = 0;
  wire [3:0] wr_slot = cfg_step[4:1];
  wire wr_lo = cfg_step < 8 && !cfg_step[0];
  wire wr_hi = cfg_step < 8 && cfg_step[0];
  reg [15:0] cfg_word;
  always @(*) begin
    case (cfg_step[4:1])
      0: cfg_word = 16'h4008;
      1: cfg_word = 16'h3690;
      2: cfg_word = 16'h4c01;
      default: cfg_word = 16'h9000;
    endcase
  end
  wire [7:0] wr_data = cfg_step[0] ? cfg_word[15:8] : cfg_word[7:0];
  wire start = cfg_step == 8;
  (* anyseq *) reg tx_grant;
  (* anyseq *) reg rx_grant;

  wire tx_request, rx_request, busy, table_ready, done_pulse;
  wire [7:0] rx_data, launch_claim, claim;
  wire [15:0] result, lfsr_value;
  wire drive_enable;
  wire [7:0] drive_out_value, drive_out_mask, drive_oe_value, drive_oe_mask;

  action_lane dut (
      .clk(clk), .rst_n(rst_n), .enable(1'b1),
      .wr_lo(wr_lo), .wr_hi(wr_hi),
      .wr_bundle_lo(1'b0), .wr_bundle_hi(1'b0),
      .wr_slot(wr_slot), .wr_data(wr_data),
      .load_shift_lo(1'b0), .load_shift_hi(1'b0), .load_tx(1'b0),
      .load_data(8'b0), .load_bits(5'd8), .load_msb_first(1'b0),
      .start(start), .start_slot(4'd0), .repeat_count(8'b0),
      .pin_sampled(8'b0), .pin_timed(8'h02),
      .tx_request(tx_request), .tx_grant(tx_grant), .tx_data(8'ha5),
      .rx_request(rx_request), .rx_grant(rx_grant), .rx_data(rx_data),
      .busy(busy), .table_ready(table_ready), .done_pulse(done_pulse),
      .result(result), .lfsr_value(lfsr_value),
      .launch_claim(launch_claim), .drive_enable(drive_enable),
      .drive_out_value(drive_out_value), .drive_out_mask(drive_out_mask),
      .drive_oe_value(drive_oe_value), .drive_oe_mask(drive_oe_mask),
      .claim(claim)
  );

  reg past_valid = 0;
  reg [1:0] tx_pops = 0;
  reg [1:0] rx_pushes = 0;
  always @(posedge clk) begin
    past_valid <= 1'b1;
    if (reset_cycles != 3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      cfg_step <= 0;
      tx_pops <= 0;
      rx_pushes <= 0;
    end else begin
      if (cfg_step < 31)
        cfg_step <= cfg_step + 1'b1;
      if (tx_request && tx_grant)
        tx_pops <= tx_pops + 1'b1;
      if (rx_request && rx_grant)
        rx_pushes <= rx_pushes + 1'b1;

      assert(tx_pops <= 1);
      assert(rx_pushes <= 1);
      if (rx_request)
        assert(rx_data == 8'hff);
      if (done_pulse) begin
        assert(tx_pops == 1);
        assert(rx_pushes == 1);
        assert(result[7:0] == 8'hff);
      end
      if (past_valid && $past(rst_n && tx_request && !tx_grant)) begin
        assert(tx_request);
        assert(busy);
      end
      if (past_valid && $past(rst_n && rx_request && !rx_grant)) begin
        assert(rx_request);
        assert(busy);
      end

      cover(done_pulse && tx_pops == 1 && rx_pushes == 1);
      cover(tx_request && !tx_grant);
      cover(rx_request && !rx_grant);
    end
  end

  wire _unused = &{table_ready, launch_claim, claim, lfsr_value,
                   drive_enable, drive_out_value, drive_out_mask,
                   drive_oe_value, drive_oe_mask, 1'b0};
endmodule

`default_nettype wire
