`default_nettype none

module action_dispatcher_properties;
  (* gclk *) reg clk;
  (* anyseq *) reg target_lane;
  (* anyseq *) reg [1:0] lane_busy;
  (* anyseq *) reg [1:0] lane_table_ready;
  (* anyseq *) reg [7:0] launch_claim_0, launch_claim_1;
  (* anyseq *) reg [7:0] active_claim_0, active_claim_1;
  (* anyseq *) reg [1:0] tx_request, rx_request;
  (* anyseq *) reg tx_priority, rx_priority, tx_empty, rx_full;
  wire control_ready, table_ready, start_ready;
  wire [1:0] tx_grant, rx_grant;

  action_dispatcher dut (.*);

  wire selected_busy = target_lane ? lane_busy[1] : lane_busy[0];
  wire selected_table = target_lane ? lane_table_ready[1] : lane_table_ready[0];
  wire [7:0] selected_launch = target_lane ? launch_claim_1 : launch_claim_0;
  wire [7:0] other_active = target_lane ? active_claim_0 : active_claim_1;

  always @(posedge clk) begin
    assert(control_ready == !selected_busy);
    assert(table_ready == selected_table);
    assert(start_ready == (!selected_busy && selected_table &&
                           !(|(selected_launch & other_active))));
    assert(!(tx_grant[0] && tx_grant[1]));
    assert(!(rx_grant[0] && rx_grant[1]));
    assert((tx_grant & ~tx_request) == 0);
    assert((rx_grant & ~rx_request) == 0);
    if (tx_empty) assert(tx_grant == 0);
    if (rx_full) assert(rx_grant == 0);
    if (!tx_empty && tx_request == 2'b11)
      assert(tx_grant == (tx_priority ? 2'b10 : 2'b01));
    if (!rx_full && rx_request == 2'b11)
      assert(rx_grant == (rx_priority ? 2'b10 : 2'b01));

    cover(!start_ready && !selected_busy && selected_table &&
          |(selected_launch & other_active));
    cover(tx_grant == 2'b01);
    cover(tx_grant == 2'b10);
  end
endmodule

`default_nettype wire
