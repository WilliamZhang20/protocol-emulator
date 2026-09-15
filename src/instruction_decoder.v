`default_nettype none

// Decodes one compact instruction byte.
// Selects datapath operations and immediate fields.
// Produces branch, stall, and resource control signals.
module instruction_decoder (
    input  wire [7:0] instruction,
    output wire [3:0] opcode,
    output wire [3:0] immediate,
    output wire       branch_enable,
    output wire       delay_enable,
    output wire       gpio_enable,
    output wire       shift_enable
);
endmodule

`default_nettype wire
