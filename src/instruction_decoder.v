`default_nettype none

// Decodes one compact instruction byte.
module instruction_decoder (
    input  wire [7:0] instruction,
    output wire [3:0] opcode,
    output wire [3:0] immediate,
    output wire       branch_enable,
    output wire       delay_enable,
    output wire       gpio_enable,
    output wire       shift_enable,
    output wire       event_enable
);
  assign opcode = instruction[7:4];
  assign immediate = instruction[3:0];
  assign branch_enable = opcode == 4'h8 || opcode == 4'h9;
  assign delay_enable = opcode == 4'h1 || opcode == 4'he;
  assign gpio_enable = opcode == 4'h2 || opcode == 4'h3 ||
                       opcode == 4'h9 || opcode == 4'hb;
  assign shift_enable = ((opcode >= 4'h4) && (opcode <= 4'h6)) ||
                        opcode == 4'ha;
  assign event_enable = opcode == 4'hd || opcode == 4'hf;
endmodule

`default_nettype wire
