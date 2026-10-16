`default_nettype none

// The whole spatial core (controller, all tiles, pin cells, FIFO channel
// ports) running an arbitrary program from a symbolic SRAM against
// arbitrary pins and FIFO states. Properties that hold for every program:
//  * arming: arming the fabric takes a config write to 0x31, which ends
//    in the byte WCF n=1 (8'h81) or, in a block config load, starts with
//    the address byte 8'h31; until the SRAM has returned one of those
//    bytes no pin is ever driven;
//  * the engine stopped means the pins are released a cycle later;
//  * FIFO channels: no pop from an empty FIFO, no push into a full one;
//  * a disabled engine is not halted a cycle later.
// Single-clock harness: one solver step is one clock cycle.
module fabric_core_properties (input wire clk);
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyconst *) reg [255:0] rom;
  (* anyseq *) reg        enable;
  (* anyseq *) reg [15:0] tx_data;
  (* anyseq *) reg [1:0]  tx_empty;
  (* anyseq *) reg [1:0]  tx_full;
  (* anyseq *) reg [1:0]  rx_full;
  (* anyseq *) reg [7:0]  gpio_in;

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire [1:0]  tx_pop, tx_push, rx_push;
  wire [7:0]  tx_push_data, gpio_out, gpio_oe;
  wire [15:0] rx_data;
  wire        halted;

  reg [7:0] instruction_data = 8'd0;
  always @(posedge clk)
    if (instruction_read)
      instruction_data <= rom[{instruction_address[4:0], 3'b000} +: 8];

  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data(tx_data), .tx_empty(tx_empty), .tx_pop(tx_pop),
      .tx_full(tx_full), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(rx_full),
      .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  reg arm_byte_seen = 1'b0;
  reg past_valid = 1'b0, past_enable = 1'b0;
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    past_valid <= rst_n;
    past_enable <= enable;
    if (!rst_n)
      arm_byte_seen <= 1'b0;
    else if (instruction_data == 8'h81 || instruction_data == 8'h31)
      arm_byte_seen <= 1'b1;
  end

  always @(*) begin
    if (rst_n && past_valid) begin
      if (!arm_byte_seen) assert(gpio_oe == 8'd0 && gpio_out == 8'd0);
      if (!past_enable) assert(gpio_oe == 8'd0 && gpio_out == 8'd0);
      assert((tx_pop & tx_empty) == 2'd0);
      assert((rx_push & rx_full) == 2'd0);
      assert((tx_push & tx_full) == 2'd0);
      assert(tx_push != 2'b11);           // the controller feeds one channel
      if (!past_enable) assert(!halted);
      cover(gpio_oe != 8'd0);
    end
  end
endmodule

`default_nettype wire
