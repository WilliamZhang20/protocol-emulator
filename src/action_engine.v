`default_nettype none

// Two-lane real-time subsystem. Target bit 4 selects a lane; target bits
// 3:0 select one of its 16 action slots. The dispatcher admits complete pin
// claims atomically and arbitrates shared FIFOs fairly.
module action_engine (
    input wire clk, rst_n, enable, target_lane,
    input wire wr_lo, wr_hi, wr_lane_lo, wr_lane_hi,
    input wire [3:0] wr_slot,
    input wire [7:0] wr_data,
    input wire load_shift, load_shift_hi, load_tx,
    input wire [4:0] tx_bits,
    input wire tx_msb_first,
    input wire [7:0] shift_data,
    input wire start,
    input wire [3:0] start_slot,
    input wire [7:0] repeat_count,
    input wire [7:0] pin_sampled, pin_timed, tx_data,
    input wire tx_empty,
    output wire tx_pop,
    input wire rx_full,
    output wire rx_push,
    output wire [7:0] rx_data,
    output wire busy,
    output wire [1:0] busy_mask,
    output wire control_ready, table_ready, start_ready,
    output wire done_pulse,
    output wire [1:0] done_count,
    output wire done_lane,
    output wire [15:0] result, lfsr_value,
    output wire drive_enable,
    output wire [7:0] drive_out_value, drive_out_mask,
    output wire [7:0] drive_oe_value, drive_oe_mask,
    output wire [7:0] claim
);
  wire [1:0] lane_busy, lane_ready, lane_done;
  wire [7:0] lane_claim_0, lane_claim_1;
  wire [7:0] launch_claim_0, launch_claim_1;
  wire [15:0] lane_result_0, lane_result_1;
  wire [15:0] lane_lfsr_0, lane_lfsr_1;
  wire [1:0] lane_tx_request, lane_rx_request;
  wire [1:0] lane_tx_grant, lane_rx_grant;
  wire [7:0] lane_rx_data_0, lane_rx_data_1;
  wire lane_drive_0, lane_drive_1;
  wire [7:0] lane_out_0, lane_out_1, lane_out_mask_0, lane_out_mask_1;
  wire [7:0] lane_oe_0, lane_oe_1, lane_oe_mask_0, lane_oe_mask_1;

  assign busy_mask = lane_busy;
  assign busy = |lane_busy;
  assign done_pulse = |lane_done;
  assign done_count = {1'b0, lane_done[0]} + {1'b0, lane_done[1]};
  assign done_lane = lane_done[1];
  assign result = target_lane ? lane_result_1 : lane_result_0;
  assign lfsr_value = target_lane ? lane_lfsr_1 : lane_lfsr_0;
  assign claim = lane_claim_0 | lane_claim_1;

  // Active claims never overlap, so masked OR has explicit collision semantics.
  assign drive_enable = lane_drive_0 | lane_drive_1;
  assign drive_out_mask = lane_out_mask_0 | lane_out_mask_1;
  assign drive_out_value = (lane_out_0 & lane_out_mask_0) |
                           (lane_out_1 & lane_out_mask_1);
  assign drive_oe_mask = lane_oe_mask_0 | lane_oe_mask_1;
  assign drive_oe_value = (lane_oe_0 & lane_oe_mask_0) |
                          (lane_oe_1 & lane_oe_mask_1);

  reg tx_priority, rx_priority;
  action_dispatcher dispatcher (
      .target_lane(target_lane), .lane_busy(lane_busy),
      .lane_table_ready(lane_ready),
      .launch_claim_0(launch_claim_0), .launch_claim_1(launch_claim_1),
      .active_claim_0(lane_claim_0), .active_claim_1(lane_claim_1),
      .tx_request(lane_tx_request), .rx_request(lane_rx_request),
      .tx_priority(tx_priority), .rx_priority(rx_priority),
      .tx_empty(tx_empty), .rx_full(rx_full),
      .control_ready(control_ready), .table_ready(table_ready),
      .start_ready(start_ready), .tx_grant(lane_tx_grant),
      .rx_grant(lane_rx_grant)
  );
  assign tx_pop = |lane_tx_grant;
  assign rx_push = |lane_rx_grant;
  assign rx_data = lane_rx_grant[1] ? lane_rx_data_1 : lane_rx_data_0;

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      tx_priority <= 1'b0;
      rx_priority <= 1'b0;
    end else begin
      if (lane_tx_grant[0]) tx_priority <= 1'b1;
      else if (lane_tx_grant[1]) tx_priority <= 1'b0;
      if (lane_rx_grant[0]) rx_priority <= 1'b1;
      else if (lane_rx_grant[1]) rx_priority <= 1'b0;
    end
  end

  action_lane lane0 (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .wr_lo(wr_lo && !target_lane), .wr_hi(wr_hi && !target_lane),
      .wr_bundle_lo(wr_lane_lo && !target_lane),
      .wr_bundle_hi(wr_lane_hi && !target_lane),
      .wr_slot(wr_slot), .wr_data(wr_data),
      .load_shift_lo(load_shift && !target_lane),
      .load_shift_hi(load_shift_hi && !target_lane),
      .load_tx(load_tx && !target_lane),
      .load_data(load_tx ? tx_data : shift_data),
      .load_bits(tx_bits), .load_msb_first(tx_msb_first),
      .start(start && !target_lane && start_ready),
      .start_slot(start_slot), .repeat_count(repeat_count),
      .pin_sampled(pin_sampled), .pin_timed(pin_timed),
      .tx_request(lane_tx_request[0]), .tx_grant(lane_tx_grant[0]),
      .tx_data(tx_data), .rx_request(lane_rx_request[0]),
      .rx_grant(lane_rx_grant[0]), .rx_data(lane_rx_data_0),
      .busy(lane_busy[0]), .table_ready(lane_ready[0]),
      .done_pulse(lane_done[0]), .result(lane_result_0),
      .lfsr_value(lane_lfsr_0), .launch_claim(launch_claim_0),
      .drive_enable(lane_drive_0), .drive_out_value(lane_out_0),
      .drive_out_mask(lane_out_mask_0), .drive_oe_value(lane_oe_0),
      .drive_oe_mask(lane_oe_mask_0), .claim(lane_claim_0)
  );

  action_lane lane1 (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .wr_lo(wr_lo && target_lane), .wr_hi(wr_hi && target_lane),
      .wr_bundle_lo(wr_lane_lo && target_lane),
      .wr_bundle_hi(wr_lane_hi && target_lane),
      .wr_slot(wr_slot), .wr_data(wr_data),
      .load_shift_lo(load_shift && target_lane),
      .load_shift_hi(load_shift_hi && target_lane),
      .load_tx(load_tx && target_lane),
      .load_data(load_tx ? tx_data : shift_data),
      .load_bits(tx_bits), .load_msb_first(tx_msb_first),
      .start(start && target_lane && start_ready),
      .start_slot(start_slot), .repeat_count(repeat_count),
      .pin_sampled(pin_sampled), .pin_timed(pin_timed),
      .tx_request(lane_tx_request[1]), .tx_grant(lane_tx_grant[1]),
      .tx_data(tx_data), .rx_request(lane_rx_request[1]),
      .rx_grant(lane_rx_grant[1]), .rx_data(lane_rx_data_1),
      .busy(lane_busy[1]), .table_ready(lane_ready[1]),
      .done_pulse(lane_done[1]), .result(lane_result_1),
      .lfsr_value(lane_lfsr_1), .launch_claim(launch_claim_1),
      .drive_enable(lane_drive_1), .drive_out_value(lane_out_1),
      .drive_out_mask(lane_out_mask_1), .drive_oe_value(lane_oe_1),
      .drive_oe_mask(lane_oe_mask_1), .claim(lane_claim_1)
  );
endmodule

`default_nettype wire
