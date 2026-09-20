`default_nettype none

module byte_fifo_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  (* anyseq *) reg push;
  (* anyseq *) reg pop;
  (* anyseq *) reg [7:0] push_data;
  wire [7:0] pop_data;
  wire empty;
  wire full;
  wire [2:0] level;

  byte_fifo #(.DEPTH(4), .ADDRESS_WIDTH(2)) dut (
      .clk(clk), .rst_n(rst_n),
      .push(push), .push_data(push_data), .pop(pop),
      .pop_data(pop_data), .empty(empty), .full(full), .level(level)
  );

  // Abstract FIFO in age order. The RTL uses rotating pointers; this model
  // shifts the oldest byte to index zero on each accepted pop.
  reg [7:0] expected [0:3];
  reg [2:0] expected_count = 3'd0;
  wire pop_accept = pop && expected_count != 3'd0;
  wire push_accept = push && (expected_count != 3'd4 || pop_accept);
  integer i;

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      expected_count <= 3'd0;
      for (i = 0; i < 4; i = i + 1)
        expected[i] <= 8'b0;
    end else begin
      assert(level == expected_count);
      assert(expected_count <= 3'd4);
      assert(empty == (expected_count == 3'd0));
      assert(full == (expected_count == 3'd4));
      if (expected_count != 3'd0)
        assert(pop_data == expected[0]);

      if (pop_accept) begin
        expected[0] <= expected[1];
        expected[1] <= expected[2];
        expected[2] <= expected[3];
      end
      if (push_accept)
        expected[expected_count - pop_accept] <= push_data;
      case ({push_accept, pop_accept})
        2'b10: expected_count <= expected_count + 1'b1;
        2'b01: expected_count <= expected_count - 1'b1;
        default: expected_count <= expected_count;
      endcase

      cover(full && push && pop);
      cover(empty && push);
    end
  end
endmodule

`default_nettype wire
