`default_nettype none

// Protocol proof: the whole core runs the real quadrature decoder program
// (rom.vh) against symbolic A and B inputs that may change, together or
// alone, at any time at least GAP cycles after their last change. A
// reference decoder works on the raw pins: a change of exactly one input
// is a step, forward when the new A differs from the old B; a change of
// both is a missed step. Then: every RX byte on channel 0 is the next step
// (1 forward, 0 back), every byte on channel 1 the next missed step;
// nothing else is pushed; every event is pushed within LATENCY cycles, so
// none is ever lost.
module quadrature_decoder_properties (input wire clk);
  localparam A = 0, B = 1, GAP = 2, LATENCY = 8;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  // The program drives no pin; it has armed once the controller fetches
  // its final idle loop (the last 3 code bytes). Until then the inputs
  // hold at 00, so everything before is one deterministic run.
  reg configured = 1'b0;
  (* anyseq *) reg       move;
  (* anyseq *) reg [1:0] next_ab;
  reg [1:0] ab = 2'b00, ab_q = 2'b00;
  reg [3:0] quiet = 4'd0;            // cycles since A/B last changed

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire [1:0]  tx_pop, tx_push, rx_push;
  wire [9:0]  tx_push_data;
  wire [7:0]  gpio_out, gpio_oe;
  wire [19:0] rx_data;
  wire        halted;
  reg  [7:0]  instruction_data = 8'd0;
  always @(posedge clk)
    if (instruction_read)
      instruction_data <= rom_byte(instruction_address);

  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(rst_n),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data(20'd0), .tx_empty(2'b11), .tx_pop(tx_pop),
      .tx_full(2'b00), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(2'b00),
      .gpio_in({6'b111111, ab[B], ab[A]}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && instruction_read && instruction_address == CODE_LENGTH - 3)
      configured <= 1'b1;
    if (configured && move && quiet >= GAP - 1 && next_ab != ab) begin
      ab <= next_ab;
      quiet <= 4'd0;
    end else if (quiet != 4'hf)
      quiet <= quiet + 4'd1;
    ab_q <= ab;
  end

  // Reference decoder and the events still due on each channel.
  wire a_changed = ab[A] != ab_q[A];
  wire b_changed = ab[B] != ab_q[B];
  wire step   = a_changed != b_changed;
  wire missed = a_changed && b_changed;
  wire forward = ab[A] != ab_q[B];
  reg [3:0] steps = 4'd0;            // due steps, oldest in bit 0
  reg [2:0] steps_n = 3'd0;
  reg [2:0] missed_n = 3'd0;
  reg [3:0] step_age = 4'd0, missed_age = 4'd0;   // age of the oldest due
  wire pop0 = rx_push[0], pop1 = rx_push[1];
  wire [2:0] steps_after = steps_n - pop0;

  always @(posedge clk) begin
    if (!rst_n) begin
      steps_n <= 3'd0; missed_n <= 3'd0; step_age <= 4'd0; missed_age <= 4'd0;
    end else begin
      steps <= (pop0 ? steps >> 1 : steps);
      if (step) steps[steps_after] <= forward;
      steps_n <= steps_after + step;
      missed_n <= missed_n - pop1 + missed;
      step_age <= (pop0 || steps_n == 3'd0) ? 4'd0 : step_age + 4'd1;
      missed_age <= (pop1 || missed_n == 3'd0) ? 4'd0 : missed_age + 4'd1;
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(tx_pop == 2'b00 && gpio_oe == 8'd0);
      if (!configured) assert(rx_push == 2'b00);
      if (pop0) assert(steps_n != 3'd0 && rx_data[7:0] == {7'd0, steps[0]});
      if (pop1) assert(missed_n != 3'd0);
      assert(step_age < LATENCY && missed_age < LATENCY);
      cover(pop0 && rx_data[0] && steps_n == 3'd2);
      cover(pop0 && !rx_data[0]);
      cover(pop1);
    end
  end
endmodule

`default_nettype wire
