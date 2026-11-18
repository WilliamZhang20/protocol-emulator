`default_nettype none

// Small, configured protocol-control actor. Unlike the program controller,
// this tile has no PC or instruction stream: it advances a local 2-bit state
// from one selected registered fabric event and emits one-cycle action lines.
// Two instances are placed beside the two byte/shifter channels.
//
// Config map (controller writes; address includes actor index):
//   0x90-0x9f  transition rows: actor 0 at 0x90-0x97, actor 1 at 0x98-0x9f
//              row = {state[1:0], event_value}; data[1:0] = next state,
//              data[4:2] = one-hot action (000: none, 001/010/100: action)
//   0xa0-0xa1  selected signal-space event line in data[5:0]
//
// Rows for event_value=0 can implement falling-edge transitions. For a
// level that stays high after a transition, the new state's high row should
// hold state and emit no action unless another transition is intended.
module fabric_control_actor #(
    parameter integer ACTOR = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire       cfg_we,
    input  wire [7:0] cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [63:0] lines,
    output wire [2:0] action
);
  reg [4:0] transition [0:7];
  reg [5:0] event_select;
  reg [1:0] state;
  reg [2:0] action_q;

  wire [2:0] row = {state, lines[event_select]};
  wire [4:0] transition_data = transition[row];

  assign action = action_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      event_select <= 6'd0;
      state <= 2'd0;
      action_q <= 3'd0;
    end else begin
      if (cfg_we && cfg_addr == (8'ha0 + ACTOR))
        event_select <= cfg_data[5:0];

      if (!enable) begin
        state <= 2'd0;
        action_q <= 3'd0;
      end else begin
        state <= transition_data[1:0];
        action_q <= transition_data[4:2];
      end
    end
  end

  genvar row_index;
  generate
    for (row_index = 0; row_index < 8; row_index = row_index + 1) begin : rows
      always @(posedge clk)
        if (!rst_n)
          transition[row_index] <= {3'b000, row_index[2:1]};
        else if (cfg_we && cfg_addr == (8'h90 + ACTOR * 8 + row_index))
          transition[row_index] <= cfg_data[4:0];
    end
  endgenerate
endmodule

`default_nettype wire
