`default_nettype none

// Buffers bytes between the host and protocol engine.
// Decouples host service latency from exact-cycle execution.
// Reports occupancy and flow-control status at both ends.
module byte_fifo #(
    parameter DEPTH = 4,
    parameter ADDRESS_WIDTH = 2
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   push,
    input  wire [7:0]             push_data,
    input  wire                   pop,
    output wire [7:0]             pop_data,
    output wire                   empty,
    output wire                   full,
    output wire [ADDRESS_WIDTH:0] level
);
  reg [7:0] memory [0:DEPTH-1];
  reg [ADDRESS_WIDTH-1:0] read_pointer;
  reg [ADDRESS_WIDTH-1:0] write_pointer;
  reg [ADDRESS_WIDTH:0] count;
  localparam [ADDRESS_WIDTH-1:0] LAST_ADDRESS =
      DEPTH[ADDRESS_WIDTH-1:0] - 1'b1;
  localparam [ADDRESS_WIDTH:0] FIFO_DEPTH = DEPTH;
  wire pop_accepted = pop && !empty;
  wire push_accepted = push && (!full || pop_accepted);

  assign pop_data = memory[read_pointer];
  assign empty = count == 0;
  assign full = count == FIFO_DEPTH;
  assign level = count;

  always @(posedge clk) begin
    if (!rst_n) begin
      read_pointer <= {ADDRESS_WIDTH{1'b0}};
      write_pointer <= {ADDRESS_WIDTH{1'b0}};
      count <= {(ADDRESS_WIDTH + 1){1'b0}};
    end else begin
      if (push_accepted) begin
        memory[write_pointer] <= push_data;
        if (write_pointer == LAST_ADDRESS)
          write_pointer <= {ADDRESS_WIDTH{1'b0}};
        else
          write_pointer <= write_pointer + 1'b1;
      end
      if (pop_accepted) begin
        if (read_pointer == LAST_ADDRESS)
          read_pointer <= {ADDRESS_WIDTH{1'b0}};
        else
          read_pointer <= read_pointer + 1'b1;
      end
      case ({push_accepted, pop_accepted})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule

`default_nettype wire
