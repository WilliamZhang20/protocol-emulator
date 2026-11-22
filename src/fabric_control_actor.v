`default_nettype none

// SPATIAL_ACTOR_ABI: 2
// Small, configured protocol-control actor. Unlike the program controller,
// this tile has no PC or instruction stream: it advances a small local state
// from two selected registered fabric conditions and emits one-cycle actions.
// Two instances are placed beside the two byte/shifter channels.
//
// Config map (controller writes; address includes actor index):
//   0x90-0x9f  packed transition rows: eight 16-bit words per actor
//              row = {state[1:0], input2, input1}; each word packs two rows
//              data[1:0]/[6:5] = next state, data[4:2]/[9:7] = action bits
//   0xa0-0xa1  selected signal-space lines: input1 in data[5:0],
//              input2 in data[11:6], eight-state one-input mode in data[12]
//
// Rows can distinguish a pulse/event from a second level such as ACK/NACK.
// For a level that stays high after a transition, configure the new state's
// matching row to hold state and emit no action unless another transition is
// intended.
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
  reg [15:0] transition_pair [0:7];
  reg [11:0] event_select;
  reg wide_state;
  reg [2:0] state;
  reg [2:0] action_q;
  localparam [7:0] EVENT_SELECT_ADDR = {4'ha, 3'b000, ACTOR[0]};

  wire [3:0] compact_row = {state[1:0], lines[event_select[11:6]], lines[event_select[5:0]]};
  wire [3:0] wide_row = {state, lines[event_select[5:0]]};
  wire [3:0] row = wide_state ? wide_row : compact_row;
  wire [15:0] transition_word = transition_pair[row[3:1]];
  wire [4:0] compact_data = row[0] ? transition_word[9:5] : transition_word[4:0];
  wire [5:0] wide_data = row[0] ? transition_word[11:6] : transition_word[5:0];
  wire [2:0] next_state = wide_state ? wide_data[2:0] : {1'b0, compact_data[1:0]};
  wire [2:0] next_action = wide_state ? wide_data[5:3] : compact_data[4:2];

  assign action = action_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      event_select <= 12'd0;
      wide_state <= 1'b0;
      state <= 3'd0;
      action_q <= 3'd0;
    end else begin
      if (cfg_we && cfg_addr == EVENT_SELECT_ADDR) begin
        event_select <= cfg_data[11:0];
        wide_state <= cfg_data[12];
      end

      if (!enable) begin
        state <= 3'd0;
        action_q <= 3'd0;
      end else begin
        state <= next_state;
        action_q <= next_action;
      end
    end
  end

  genvar row_index;
  generate
    for (row_index = 0; row_index < 8; row_index = row_index + 1) begin : rows
      localparam [7:0] WORD_ADDR = {4'h9, ACTOR[0], row_index[2:0]};
      localparam [1:0] RESET_STATE = row_index[2:1];
      localparam [15:0] RESET_PAIR = {
          6'b0, 3'b0, RESET_STATE, 3'b0, RESET_STATE
      };
      always @(posedge clk)
        if (!rst_n)
          transition_pair[row_index] <= RESET_PAIR;
        else if (cfg_we && cfg_addr == WORD_ADDR)
          transition_pair[row_index] <= cfg_data;
    end
  endgenerate
endmodule

`default_nettype wire
