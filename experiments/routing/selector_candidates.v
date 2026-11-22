`default_nettype none

// Selector-only proxy for one consumer of today's 64-line space. Select is a
// configuration input held stable during operation; it is not a data input.
module global_selector (
    input wire clk,
    input wire [63:0] sources,
    input wire [5:0] select,
    output reg out
);
  always @(posedge clk) out <= sources[select];
endmodule

// Reachability control for the local candidate: the same seven local and
// eight remote signals, but selected in one cycle by a flat mux. Input 15 is
// tied to zero, so this still cannot express the full 64-line baseline.
module flat15_selector (
    input wire clk,
    input wire [6:0] local_sources,
    input wire [7:0] remote_sources,
    input wire [3:0] select,
    output reg out
);
  wire [15:0] candidates = {1'b0, remote_sources, local_sources};
  always @(posedge clk) out <= candidates[select];
endmodule

// One restricted locality hypothesis: seven direct sources and one incoming
// registered route, which selects one of eight remote sources. Reachability
// (15 sources, not 64) and relay latency differ from global_selector.
module local_selector (
    input wire clk,
    input wire [6:0] local_sources,
    input wire [7:0] remote_sources,
    input wire [2:0] select,
    input wire [2:0] remote_select,
    output reg out
);
  reg relay;
  wire [7:0] candidates = {relay, local_sources};
  always @(posedge clk) begin
    relay <= remote_sources[remote_select];
    out <= candidates[select];
  end
endmodule

`default_nettype wire
