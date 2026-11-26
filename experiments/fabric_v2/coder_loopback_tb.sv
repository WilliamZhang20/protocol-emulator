`default_nettype none
// Coded shifter receive side, end to end: a transmitting fabric_shifter
// drives a receiving one (coder [5] set) over one line. Random framing
// (length, bit order, pre/post bits, parity), stuffing (N 1-6, runs of
// equal bits or of ones), NRZI and Manchester; random words. Both tiles
// share one tick line (TX shift, RX shift and sample; Manchester RX ticks
// twice per bit). Every received word must equal the sent word, with no
// error tag. Then the negative cases: a corrupted stuff bit, a corrupted
// parity bit and a Manchester code violation must each be flagged.
module coder_loopback_tb;
  reg clk = 0, rst_n = 0;
  always #5 clk = !clk;

  reg tick = 0, start = 0, flip = 0;
  reg cfg_we = 0; reg [2:0] cfg_addr = 0; reg [15:0] cfg_data = 0; reg to_rx = 0;
  wire tx_out, rx_in;
  wire [63:0] tx_lines = {32'b0, 28'b0, start, tick, 2'b0};
  wire [63:0] rx_lines = {30'b0, rx_in, 1'b0, 28'b0, start, tick, 2'b0};
  assign rx_in = tx_out ^ flip;

  wire t_pulls, t_txreq, t_rxreq, t_eop, t_err, t_active, t_word, t_stop, t_abs, t_bit, t_emit;
  wire [7:0] t_byte; wire [15:0] t_data, t_status;
  fabric_shifter tx(.clk(clk), .rst_n(rst_n), .enable(1'b1), .cfg_we(cfg_we && !to_rx), .cfg_addr(cfg_addr),
      .cfg_data(cfg_data), .cfg_bank(2'b11), .ctx_next(1'b0), .lines(tx_lines), .pulls(t_pulls),
      .tx_request(t_txreq), .tx_grant(1'b0), .tx_data(8'd0), .tx_eop(1'b0), .tx_err(1'b0),
      .rx_request(t_rxreq), .rx_grant(1'b1), .crc_in(1'b0), .rx_byte(t_byte), .rx_eop(t_eop), .rx_err(t_err),
      .out(tx_out), .active(t_active), .word_pulse(t_word), .stop_pulse(t_stop), .rx_data(t_data),
      .status(t_status), .crc_absorb(t_abs), .crc_bit(t_bit), .crc_emit(t_emit));
  wire r_pulls, r_txreq, r_rxreq, r_eop, r_err, r_out, r_active, r_word, r_stop, r_abs, r_bit, r_emit;
  wire [7:0] r_byte; wire [15:0] r_data, r_status;
  fabric_shifter rx(.clk(clk), .rst_n(rst_n), .enable(1'b1), .cfg_we(cfg_we && to_rx), .cfg_addr(cfg_addr),
      .cfg_data(cfg_data), .cfg_bank(2'b11), .ctx_next(1'b0), .lines(rx_lines), .pulls(r_pulls),
      .tx_request(r_txreq), .tx_grant(1'b0), .tx_data(8'd0), .tx_eop(1'b0), .tx_err(1'b0),
      .rx_request(r_rxreq), .rx_grant(1'b1), .crc_in(1'b0), .rx_byte(r_byte), .rx_eop(r_eop), .rx_err(r_err),
      .out(r_out), .active(r_active), .word_pulse(r_word), .stop_pulse(r_stop), .rx_data(r_data),
      .status(r_status), .crc_absorb(r_abs), .crc_bit(r_bit), .crc_emit(r_emit));

  integer errors = 0, frames = 0, i, seen_push;
  reg got_err;
  reg [7:0] got_byte;
  always @(posedge clk) if (r_rxreq) begin seen_push <= 1; got_byte <= r_byte; got_err <= r_err; end

  task automatic write(input rx_side, input [2:0] a, input [15:0] d);
    begin
      @(negedge clk); to_rx = rx_side; cfg_we = 1; cfg_addr = a; cfg_data = d;
      @(negedge clk); cfg_we = 0;
    end
  endtask

  // Ticks every `gap` clocks while either tile is active.
  task automatic run_frame(input integer gap, input integer half);
    integer n;
    begin
      seen_push = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      n = 0;
      while ((t_active || r_active) && n < 2000) begin
        repeat (gap - 1) @(negedge clk);
        tick = 1; @(negedge clk); tick = 0;
        n = n + 1;
      end
      repeat (4) @(negedge clk);
    end
  endtask

  // One configuration for both tiles: frame word, coder word (TX copy; the
  // RX copy has bit 5 set), data.
  task automatic configure(input [15:0] frame, input [15:0] coder, input [15:0] word);
    begin
      write(0, 3'd1, frame); write(1, 3'd1, frame);
      write(0, 3'd2, {6'd2, 6'd2}); write(1, 3'd2, {6'd2, 6'd2});
      write(0, 3'd3, 13'd3);                         // start line 3
      write(1, 3'd3, {1'b1, 1'b0, 5'd1, 6'd3});      // auto push, input level 1, start line 3
      write(0, 3'd5, coder); write(1, 3'd5, coder | 16'h0020);
      write(0, 3'd0, word);
    end
  endtask

  reg [3:0] len_m1; reg [1:0] pre_n, post_n, parity; reg pre_v, post_v, msb, idle;
  reg [2:0] stuff; reg ones, nrzi, manch;
  reg [15:0] word, frame, coder, mask;
  integer gap, k;

  initial begin
    repeat (3) @(negedge clk); rst_n = 1;
    for (i = 0; i < 600; i = i + 1) begin
      len_m1 = $urandom % 16; pre_n = $urandom % 4; post_n = $urandom % 4;
      pre_v = $urandom % 2; post_v = $urandom % 2; msb = $urandom % 2; idle = $urandom % 2;
      parity = $urandom % 3;
      manch = ($urandom % 4) == 0;
      nrzi = !manch && ($urandom % 2);
      stuff = $urandom % 7;
      ones = $urandom % 2;
      if (stuff == 1) ones = 1;   // N=1 equal-bits stuffing is invalid configuration
      word = $urandom;
      frame = {idle, 1'b0, 1'b0, msb, parity, post_v, post_n, pre_v, pre_n, len_m1};
      coder = {manch, 6'd0, 1'b0, 1'b0, 1'b0, 1'b0, nrzi, ones, stuff};
      configure(frame, coder, word);
      // Manchester TX ticks twice per bit; RX samples on every tick (both
      // halves). Neither changes the meaning of the shared tick.
      run_frame(3 + $urandom % 3, manch);
      frames = frames + 1;
      mask = 16'hffff >> (15 - len_m1);
      if ((r_data & mask) !== (word & mask) || !seen_push || got_err || r_status[4] || r_status[5]) begin
        errors = errors + 1;
        if (errors < 10)
          $display("FAIL frame %0d: len %0d msb %0d pre %0d/%0d post %0d/%0d par %0d stuff %0d ones %0d nrzi %0d manch %0d: sent %h got %h push %0d err %0d status %h",
                   i, len_m1 + 1, msb, pre_n, pre_v, post_n, post_v, parity, stuff, ones, nrzi, manch,
                   word & mask, r_data & mask, seen_push, got_err, r_status);
      end
    end

    // Negative: invert the line for one tick in the middle of a stuffed
    // all-ones word (a stuff bit or a data bit next to it); the receiver
    // must flag it (stuff error or wrong data, never a silent good word).
    for (i = 0; i < 40; i = i + 1) begin
      frame = {1'b1, 3'b0, 2'd0, 1'b1, 2'd1, 1'b0, 2'd0, 4'd15};   // 16 ones, 1 stop bit
      coder = {13'd0, 3'd5};                                          // stuff after 5 equal bits
      configure(frame, coder, 16'hffff);
      seen_push = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      for (k = 0; k < 40 && (t_active || r_active); k = k + 1) begin
        repeat (2) @(negedge clk);
        flip = (k == 5 + i % 14);
        tick = 1; @(negedge clk); tick = 0; flip = 0;
      end
      repeat (4) @(negedge clk);
      if (!(got_err || r_status[4] || r_data != 16'hffff)) begin
        errors = errors + 1; $display("FAIL corrupted tick %0d not flagged", 5 + i % 14);
      end
    end

    // Negative: one half of one Manchester bit inverted is a code
    // violation, always flagged (status bit 5 and the err tag).
    for (i = 0; i < 32; i = i + 1) begin
      frame = {1'b0, 3'b0, 2'd0, 1'b0, 2'd0, 1'b0, 2'd0, 4'd7};      // 8 bits
      configure(frame, 16'h8000, $urandom);
      seen_push = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      for (k = 0; k < 40 && (t_active || r_active); k = k + 1) begin
        repeat (2) @(negedge clk);
        flip = (k == i % 16);
        tick = 1; @(negedge clk); tick = 0; flip = 0;
      end
      repeat (4) @(negedge clk);
      if (!(r_status[5] && got_err)) begin
        errors = errors + 1; $display("FAIL Manchester half %0d inverted not flagged", i % 16);
      end
    end
    // Negative: an inverted parity bit is flagged.
    for (i = 0; i < 8; i = i + 1) begin
      frame = {1'b1, 3'b0, 2'd1 + i[0], 1'b1, 2'd1, 1'b0, 2'd0, 4'd7};   // 8 bits, even/odd parity, stop
      configure(frame, 16'h0000, $urandom);
      seen_push = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      for (k = 0; k < 20 && (t_active || r_active); k = k + 1) begin
        repeat (2) @(negedge clk);
        flip = (k == 8);                                             // the parity bit
        tick = 1; @(negedge clk); tick = 0; flip = 0;
      end
      repeat (4) @(negedge clk);
      if (!got_err) begin errors = errors + 1; $display("FAIL inverted parity bit not flagged"); end
    end

    if (errors == 0) $display("coder loopback: PASS (%0d frames, all decoded; corruptions flagged)", frames);
    else $fatal(1, "coder loopback: %0d FAIL", errors);
    $finish;
  end
endmodule
`default_nettype wire
