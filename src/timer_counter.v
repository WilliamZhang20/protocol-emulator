`default_nettype none

// Implements exact-cycle waits and general counting.
// Loads a duration supplied by the execution core.
// Reports expiration for deterministic instruction flow.
module timer_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,
    input  wire        count_enable,
    input  wire [15:0] load_value,
    output wire [15:0] count_value,
    output wire        expired
);
endmodule

`default_nettype wire
