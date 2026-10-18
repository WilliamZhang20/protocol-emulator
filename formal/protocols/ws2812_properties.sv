`default_nettype none

// Protocol proof: the whole core runs the real WS2812 transmitter program
// (rom.vh) against a symbolic TX FIFO. The pin's high pulses spell the
// popped bytes in order, MSB first: every pulse is exactly T0H cycles for a
// 0 and T1H for a 1; the bits of one byte start exactly BIT cycles apart
// (a later byte may wait for the FIFO); no pulse without a byte; once
// armed, the pin stays driven.
module ws2812_properties (input wire clk);
  localparam BIT = 8, T0H = 2, T1H = 4, PIN = 0;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  // TX FIFO channel 0: a head byte that holds until popped; any bytes, any
  // gaps. Channel 1 stays empty.
  (* anyseq *) reg       arrive;
  (* anyseq *) reg [7:0] arriving;
  reg       has = 1'b0;
  reg [7:0] head = 8'd0;

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
      .tx_data({10'd0, 2'b00, head}), .tx_empty({1'b1, !has}), .tx_pop(tx_pop),
      .tx_full(2'b00), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(2'b00),
      .gpio_in(8'hff), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      has <= 1'b0;
    end else if (!has || tx_pop[0]) begin
      has  <= arrive;
      head <= arriving;
    end
  end

  reg [7:0] q [0:3];
  reg [2:0] count = 3'd0;
  reg [2:0] bit_index = 3'd0;        // next bit of q[0], MSB first
  reg       high = 1'b0;
  reg [7:0] high_for = 8'd0;
  reg [7:0] since_rise = 8'd0;
  reg       seen_rise = 1'b0;
  reg       armed = 1'b0;
  initial begin q[0] = 0; q[1] = 0; q[2] = 0; q[3] = 0; end
  wire level = gpio_oe[PIN] && gpio_out[PIN];
  wire rise = level && !high;
  wire fall = !level && high;
  wire this_bit = q[0][3'd7 - bit_index];
  wire byte_done = fall && bit_index == 3'd7;

  always @(posedge clk) begin
    if (!rst_n) begin
      count <= 3'd0; bit_index <= 3'd0; high <= 1'b0; armed <= 1'b0; seen_rise <= 1'b0;
    end else begin
      if (gpio_oe[PIN]) armed <= 1'b1;
      high <= level;
      high_for <= rise ? 8'd1 : high_for + 8'd1;
      since_rise <= rise ? 8'd1 : (since_rise == 8'hff ? since_rise : since_rise + 8'd1);
      if (rise) seen_rise <= 1'b1;
      if (fall) bit_index <= bit_index + 3'd1;
      if (byte_done) begin
        q[0] <= q[1]; q[1] <= q[2]; q[2] <= q[3];
      end
      if (tx_pop[0])
        q[byte_done ? count - 3'd1 : count] <= head;
      count <= count + tx_pop[0] - byte_done;
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(tx_pop[1] == 1'b0);
      assert(count <= 3'd4);
      if (rise) assert(count != 3'd0);                          // no pulse without a byte
      if (fall) assert(high_for == (this_bit ? T1H : T0H));    // exact high time per bit
      if (rise && seen_rise && bit_index != 3'd0) assert(since_rise == BIT);   // within a byte
      if (rise && seen_rise && bit_index == 3'd0) assert(since_rise >= BIT);   // between bytes
      if (armed) assert(gpio_oe[PIN]);
      cover(byte_done && q[0] == 8'h96);
    end
  end
endmodule

`default_nettype wire
