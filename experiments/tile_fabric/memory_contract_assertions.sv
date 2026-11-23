`default_nettype none
// Bindable public-interface contract. Sampled at the accepting clock edge.
// These checks complement the randomized memory-content scoreboard.
module memory_contract_assertions(
    input wire clk, input wire rst_n, input wire arm,
    input wire cfg_we, input wire [1:0] cfg_routes,
    input wire [1:0] req, input wire [1:0] we,
    input wire [19:0] addr, input wire [15:0] wdata,
    input wire [1:0] ready, input wire [1:0] rvalid);
  reg [1:0] routes;
  reg past_valid=0;
  always @(posedge clk) begin
    past_valid <= 1;
    if (!rst_n) routes <= 0;
    else if (!arm && cfg_we) routes <= cfg_routes;
  end

  // The interface uses a pulse response without backpressure. Every accepted
  // read appears exactly one edge later, including after disarm; writes never
  // generate a read response. Reset cancels a pending response.
  a_read_response: assert property (@(posedge clk) disable iff (!rst_n)
      past_valid && $past(rst_n) |-> rvalid == $past(req & ready & ~we));
  a_no_phantom_grant: assert property (@(posedge clk) disable iff (!rst_n) (ready & ~req) == 0);
  a_disarmed: assert property (@(posedge clk) disable iff (!rst_n) !arm |-> ready == 0);
  a_distinct_banks: assert property (@(posedge clk) disable iff (!rst_n)
      arm && req == 2'b11 && routes[0] != routes[1] |-> ready == 2'b11);
  a_shared_bank: assert property (@(posedge clk) disable iff (!rst_n)
      arm && req == 2'b11 && routes[0] == routes[1] |-> ready == 2'b01 || ready == 2'b10);
  // A continuous conflict alternates, bounding each wait to one accepted
  // competing request. A change to the request set ends this guarantee.
  a_fair_0: assert property (@(posedge clk) disable iff (!rst_n)
      arm && req == 2'b11 && routes[0] == routes[1] && ready == 2'b01
      |=> !arm || req != 2'b11 || routes[0] != routes[1] || ready == 2'b10);
  a_fair_1: assert property (@(posedge clk) disable iff (!rst_n)
      arm && req == 2'b11 && routes[0] == routes[1] && ready == 2'b10
      |=> !arm || req != 2'b11 || routes[0] != routes[1] || ready == 2'b01);
  // This is a requester obligation; disarm cancels an unaccepted request.
  a_hold_0: assert property (@(posedge clk) disable iff (!rst_n)
      arm && req[0] && !ready[0] |=> !arm || (req[0] && $stable({we[0],addr[9:0],wdata[7:0]})));
  a_hold_1: assert property (@(posedge clk) disable iff (!rst_n)
      arm && req[1] && !ready[1] |=> !arm || (req[1] && $stable({we[1],addr[19:10],wdata[15:8]})));
endmodule
`default_nettype wire
