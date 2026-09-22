`default_nettype none

// Combinational scoreboard for lane admission and shared FIFO grants.
module action_dispatcher (
    input  wire       target_lane,
    input  wire [1:0] lane_busy,
    input  wire [1:0] lane_table_ready,
    input  wire [7:0] launch_claim_0,
    input  wire [7:0] launch_claim_1,
    input  wire [7:0] active_claim_0,
    input  wire [7:0] active_claim_1,
    input  wire [1:0] tx_request,
    input  wire [1:0] rx_request,
    input  wire       tx_priority,
    input  wire       rx_priority,
    input  wire       tx_empty,
    input  wire       rx_full,
    output wire       control_ready,
    output wire       table_ready,
    output wire       start_ready,
    output wire [1:0] tx_grant,
    output wire [1:0] rx_grant
);
  wire selected_busy = target_lane ? lane_busy[1] : lane_busy[0];
  wire [7:0] selected_launch = target_lane ? launch_claim_1 : launch_claim_0;
  wire [7:0] other_active = target_lane ? active_claim_0 : active_claim_1;
  wire choose_tx_1 = tx_request[1] && (!tx_request[0] || tx_priority);
  wire choose_rx_1 = rx_request[1] && (!rx_request[0] || rx_priority);

  assign control_ready = !selected_busy;
  assign table_ready = target_lane ? lane_table_ready[1] : lane_table_ready[0];
  assign start_ready = control_ready && table_ready &&
                       !(|(selected_launch & other_active));
  assign tx_grant[0] = tx_request[0] && !choose_tx_1 && !tx_empty;
  assign tx_grant[1] = choose_tx_1 && !tx_empty;
  assign rx_grant[0] = rx_request[0] && !choose_rx_1 && !rx_full;
  assign rx_grant[1] = choose_rx_1 && !rx_full;
endmodule

`default_nettype wire
