`default_nettype none

// Protocol proof: the whole core runs the real HDLC transmitter program
// (rom.vh). TX FIFO channel 1 is the host: symbolic frames, any bytes, any
// length, arriving at any times, but once a frame has started its bytes
// keep coming (the host keeps ahead, as the program requires). Channel 0
// is the real 4-entry FIFO the controller copies the frames into. The
// line is read at every TXC rise, and then: TXC rises every 10 cycles; TXD is stable from 2 cycles
// before each rise to 2 after it; after the first flag the line is only
// flags and frames; no six 1s but in a flag, never seven; between two
// flags there is nothing (a flag closes one frame and opens the next) or
// a frame whose bits, after dropping the 0 that follows each five 1s, are
// the next popped frame's bytes, LSB first, then 16 bits that leave the
// CRC-16/X.25 register (fed in wire order) at its residue 16'h1D0F.
// The bound (300 cycles after arm, about 12 hours) reaches a frame's
// bytes on the line but not its closing flag (about 470), so the FCS and
// residue checks are written but not reached; the FCS is checked by the
// cocotb tests, including a loopback into the HDLC receiver, which is
// proven.
module hdlc_transmit_properties (input wire clk);
  localparam TXC = 0, TXD = 1, BIT = 10;
  localparam [15:0] POLY = 16'h1021, RESIDUE = 16'h1d0f;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  // Channel 1: the host's frames.
  (* anyseq *) reg       arrive;
  (* anyseq *) reg [7:0] arriving;
  (* anyseq *) reg       last;          // the arriving byte ends its frame
  reg       configured = 1'b0;
  reg       has1 = 1'b0, eop1 = 1'b0, mid_frame = 1'b0;
  reg [7:0] head1 = 8'd0;

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire [1:0]  tx_pop, tx_push, rx_push;
  wire [9:0]  tx_push_data;
  wire [7:0]  gpio_out, gpio_oe;
  wire [19:0] rx_data;
  wire        halted;
  wire [9:0]  head0;
  wire        empty0, full0;
  reg  [7:0]  instruction_data = 8'd0;
  always @(posedge clk)
    if (instruction_read)
      instruction_data <= rom_byte(instruction_address);

  byte_fifo #(.DEPTH(4), .ADDRESS_WIDTH(2), .WIDTH(10)) channel0 (
      .clk(clk), .rst_n(rst_n), .push(tx_push[0]), .push_data(tx_push_data),
      .pop(tx_pop[0]), .pop_data(head0), .empty(empty0), .full(full0), .level());

  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(rst_n),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data({1'b0, eop1, head1, head0}), .tx_empty({!has1, empty0}), .tx_pop(tx_pop),
      .tx_full({1'b0, full0}), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(2'b00),
      .gpio_in(8'hff), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  wire take1 = configured && (mid_frame || arrive);
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && gpio_oe != 8'd0)
      configured <= 1'b1;
    if (!rst_n) begin
      has1 <= 1'b0; mid_frame <= 1'b0;
    end else begin
      if (tx_pop[1]) mid_frame <= !eop1;
      if (!has1 || tx_pop[1]) begin
        has1  <= take1;
        head1 <= arriving;
        eop1  <= last;
      end
    end
  end

  // Bytes popped from channel 1, in order, with their eop tags.
  // Up to 9 in flight: the FIFO's 4, the 2 TX byte tiles, the shifter,
  // the controller, and one leaving the decoder's delay line. A ring of
  // 16: entry k at [9k +: 9], the oldest at frame_head.
  reg [143:0] frame_q = 144'd0;
  reg [3:0]   frame_head = 4'd0, frame_tail = 4'd0;
  reg [4:0]   frame_n = 5'd0;

  // The line at each TXC rise, and its timing.
  wire txc = gpio_out[TXC], txd = gpio_out[TXD];
  reg  txc_q = 1'b0, txd_q = 1'b1;
  reg  [3:0] stable = 4'd0;             // cycles TXD has held
  reg  [3:0] since_rise = 4'hf;
  reg        had_rise = 1'b0;
  wire rise = configured && txc && !txc_q;
  wire b = txd;
  reg  synced = 1'b0;                   // a flag has been seen
  reg  [3:0] ones = 4'd0;
  reg  [5:0] delay = 6'd0;              // the last body bits, newest in bit 0
  reg  [2:0] delay_n = 3'd0;
  reg  [7:0] body_n = 8'd0;             // body bits past the delay line
  reg  [2:0] bit_index = 3'd0;          // into the current byte
  reg        in_fcs = 1'b0;             // the frame's last byte has passed
  reg  [4:0] fcs_bits = 5'd0;
  reg  [15:0] crc = 16'hffff;
  wire stuffed = ones == 4'd5 && !b;
  wire flag_now = ones == 4'd5 && b;    // a sixth 1: this is a flag
  wire flag_end = ones == 4'd6 && !b;
  wire body_bit = synced && !stuffed && !flag_now && !flag_end && ones < 4'd6;
  // A body bit leaving the delay line is a frame bit for sure.
  wire leave = rise && body_bit && delay_n == 3'd6;
  wire out_bit = delay[5];
  wire [8:0] cur = frame_q[9 * frame_head +: 9];
  wire [15:0] crc_step = {crc[14:0], 1'b0} ^ ((crc[15] ^ out_bit) ? POLY : 16'd0);
  wire byte_end = leave && !in_fcs && bit_index == 3'd7;

  integer k;
  always @(posedge clk) begin
    if (!rst_n) begin
      frame_n <= 5'd0; frame_head <= 4'd0; frame_tail <= 4'd0;
    end else begin
      txc_q <= txc; txd_q <= txd;
      stable <= (txd != txd_q) ? 4'd0 : (stable == 4'hf ? stable : stable + 4'd1);
      since_rise <= rise ? 4'd0 : (since_rise == 4'hf ? since_rise : since_rise + 4'd1);
      if (rise) had_rise <= 1'b1;
      for (k = 0; k < 16; k = k + 1)
        if (tx_pop[1] && frame_tail == k) frame_q[9 * k +: 9] <= {eop1, head1};
      frame_tail <= frame_tail + tx_pop[1];
      frame_head <= frame_head + byte_end;
      frame_n <= frame_n - byte_end + tx_pop[1];
      if (rise) begin
        ones <= b ? (ones == 4'hf ? ones : ones + 4'd1) : 4'd0;
        if (flag_now) begin
          synced <= 1'b1;
          delay_n <= 3'd0; body_n <= 8'd0; bit_index <= 3'd0; in_fcs <= 1'b0;
          fcs_bits <= 5'd0;
          crc <= 16'hffff;
        end else if (body_bit) begin
          delay <= {delay[4:0], b};
          if (delay_n != 3'd6) delay_n <= delay_n + 3'd1;
          if (leave) begin
            body_n <= body_n + 8'd1;
            crc <= crc_step;
            if (in_fcs) fcs_bits <= fcs_bits + 5'd1;
            bit_index <= bit_index + 3'd1;
            if (byte_end && cur[8]) in_fcs <= 1'b1;
          end
        end
      end
    end
  end

  always @(*) begin
    if (rst_n && configured) begin
      assert(tx_pop[1] == 1'b0 || has1);
      assert(frame_n <= 5'd15);
      if (rise) assert(txd == txd_q && stable >= 4'd1);          // setup: 2 cycles
      if (rise && had_rise) assert(since_rise == BIT - 1);       // TXC: one rise every BIT cycles
      if (txd != txd_q) assert(since_rise >= 4'd2);              // hold: 2 cycles
      if (rise && synced) assert(!(ones >= 4'd6 && b));          // never seven 1s
      if (leave && !in_fcs) begin                                // the frame's bytes
        assert(frame_n != 5'd0);
        assert(out_bit == cur[bit_index]);
      end
      if (leave && in_fcs) assert(fcs_bits < 5'd16);              // the FCS is 16 bits
      if (rise && flag_now) begin                                // a frame ends here
        assert(body_n == 8'd0 || (in_fcs && fcs_bits == 5'd16 && crc == RESIDUE));
        if (body_n != 8'd0) assert(bit_index == 3'd0);
      end
      cover(byte_end);                                           // a frame's first byte, 311 after arm
    end
  end
endmodule

`default_nettype wire
