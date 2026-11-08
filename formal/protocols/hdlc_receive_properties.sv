`default_nettype none

// Protocol proof: the whole core runs the real HDLC receiver program
// (rom.vh) against a symbolic line: RXC is a regular clock (half period
// HALF), RXD any bit each period, changing on RXC's falling edge. A
// reference receiver works on the pins: 1s in a row are counted; after
// five, a 0 is a stuffed bit and dropped, a sixth 1 is a flag or an
// abort, which drops the partial byte and ends the packet; further 1s and
// the 0 that ends them carry nothing; every other bit is data, LSB first.
// The CRC-16/X.25 register (fed in wire order) takes every bit but the
// dropped 0s, so a good frame and its flag's sixth 1 leave 16'hA1F2, and
// it restarts at each flag. (RXC at most clk / 6: the restart, 6 cycles
// after the sixth 1, then always comes before the next bit.)
// Like the byte layer, the reference holds each packet's newest byte
// until the next byte (no tags) or the packet's end (eop, err when the
// check failed). Then every byte pushed to RX channel 1 is the next
// reference byte with exactly its tags, and nothing else is pushed.
module hdlc_receive_properties (input wire clk);
  localparam HALF = 3, RXD = 2, RXC = 3;
  localparam [15:0] POLY = 16'h1021, CHECK = 16'ha1f2;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  // The program drives no pin: it has armed once the controller fetches
  // its final idle loop (the last 3 code bytes). Until then the line idles.
  reg configured = 1'b0;
  (* anyseq *) reg next_bit;
  reg [3:0] phase = 4'd0;
  reg rxc = 1'b1, rxd = 1'b1;

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
      .gpio_in({4'b1111, rxc, rxd, 2'b11}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  // The line: RXC low for HALF cycles (RXD changes as it falls), high for
  // HALF; the bit is sampled where RXC rises.
  wire rise = configured && phase == HALF - 1 && !rxc;   // a real edge (RXC idles high)
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && instruction_read && instruction_address == CODE_LENGTH - 3)
      configured <= 1'b1;
    if (configured) begin
      phase <= (phase == 2 * HALF - 1) ? 4'd0 : phase + 4'd1;
      if (phase == 2 * HALF - 1) begin
        rxc <= 1'b0;
        rxd <= next_bit;
      end else if (phase == HALF - 1)
        rxc <= 1'b1;
    end
  end

  // Reference receiver, one step per RXC rise (on the bit now on RXD).
  reg  [3:0]  ones = 4'd0;
  reg  [15:0] crc = 16'hffff;
  reg  [7:0]  partial = 8'd0;
  reg  [3:0]  nbits = 4'd0;
  reg         held = 1'b0;           // a packet byte held for its tags
  reg  [7:0]  held_byte = 8'd0;
  wire b = rxd;
  wire stuffed = ones >= 4'd5 && !b;  // a stuffed 0, or the 0 after a flag / idle 1s
  wire flag_now = ones == 4'd5 && b;  // the sixth 1
  wire idle_one = ones >= 4'd6 && b;
  wire data_bit = !stuffed && !flag_now && !idle_one;
  wire [15:0] crc_step = {crc[14:0], 1'b0} ^ ((crc[15] ^ b) ? POLY : 16'd0);
  wire byte_done = rise && data_bit && nbits == 4'd7;
  wire [7:0] byte_now = {b, partial[7:1]};

  // Expected RX entries {err, eop, byte}, in order.
  reg [39:0] due = 40'd0;            // entry k at [10k +: 10], oldest first
  reg [2:0]  due_n = 3'd0;
  wire        emit = (byte_done && held) || (rise && flag_now && held);
  wire [9:0]  emitted = (rise && flag_now) ? {crc_step != CHECK, 1'b1, held_byte}
                                           : {2'b00, held_byte};
  wire        taken = rx_push[1];
  wire [2:0]  due_after = due_n - taken;

  always @(posedge clk) begin
    if (rise) begin
      ones <= b ? (ones == 4'hf ? ones : ones + 4'd1) : 4'd0;
      if (!stuffed) crc <= crc_step;
      if (flag_now) begin
        crc <= 16'hffff; nbits <= 4'd0; held <= 1'b0;
      end else if (data_bit) begin
        partial <= byte_now;
        nbits <= nbits == 4'd7 ? 4'd0 : nbits + 4'd1;
        if (byte_done) begin
          held <= 1'b1;
          held_byte <= byte_now;
        end
      end else if (stuffed && ones >= 4'd6) begin
        nbits <= 4'd0;                 // bytes restart after a flag's last 0
      end
    end
    if (!rst_n) begin
      due_n <= 3'd0;
    end else begin
      due <= (taken ? due >> 10 : due) |
             (emit ? {30'd0, emitted} << (10 * due_after) : 40'd0);
      due_n <= due_after + emit;
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(gpio_oe == 8'd0 && tx_pop == 2'b00 && rx_push[0] == 1'b0);
      assert(due_n <= 3'd3);
      if (taken) assert(due_n != 3'd0 && rx_data[19:10] == due[9:0]);
      cover(taken && rx_data[18] && !rx_data[19]);     // a good frame's last byte
      cover(taken && rx_data[18] && rx_data[19]);      // a bad one's
    end
  end
endmodule

`default_nettype wire
