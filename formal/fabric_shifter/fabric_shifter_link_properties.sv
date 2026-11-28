`default_nettype none

// CRC link, data bits only (coder register 6 [13]), transmit side. For any
// framing (0-3 pre bits of either value, any parity, 0-3 post bits, word
// length 1-16, bit order, idle level, burst words or single frames, FIFO
// data and timing), the link carries exactly each word's data bits in wire
// order: every absorbed bit is the next data bit of the word in flight, and
// a word ends (the next word is granted, or the tile stops) with all its
// data bits absorbed. Pre, parity and post bits never reach the CRC tile.
module fabric_shifter_link_properties (input wire clk);   // one solver step = one clock cycle
  reg [3:0] t = 4'd0;
  always @(posedge clk) if (t != 4'd15) t <= t + 4'd1;
  wire rst_n = t >= 4'd2;

  (* anyconst *) reg [3:0] len_m1;
  (* anyconst *) reg [1:0] pre, post, parity;
  (* anyconst *) reg       pre_val, post_val, msb, idle, burst;
  always @(*) assume(parity != 2'd3);

  (* anyseq *) reg       tick;
  (* anyseq *) reg       tx_ready;
  (* anyseq *) reg [7:0] tx_data;

  reg        cfg_we;
  reg [2:0]  cfg_addr;
  reg [15:0] cfg_data;
  always @(*) begin
    cfg_we = rst_n && t <= 4'd6;
    cfg_addr = 3'd0;
    cfg_data = 16'd0;
    case (t)
      4'd2: begin cfg_addr = 3'd1;
                  cfg_data = {idle, 2'b00, msb, parity, post_val, post, pre_val, pre, len_m1}; end
      4'd3: begin cfg_addr = 3'd2; cfg_data = 16'd2; end            // shift: line 2
      4'd4: begin cfg_addr = 3'd3; cfg_data = 16'd1 << 11; end      // auto pull
      4'd5: begin cfg_addr = 3'd6; cfg_data = 16'd1 << 13; end      // link data only
      4'd6: begin cfg_addr = 3'd4; cfg_data = {10'd0, burst, 5'd0}; end   // burst, end on empty
      default: ;
    endcase
  end
  wire enable = t >= 4'd7;
  wire [63:0] lines = {61'd0, enable && tick, 1'b1, 1'b0};

  wire tx_request, rx_request, out, active, word_pulse, stop_pulse, pulls;
  wire [7:0] rx_byte;
  wire rx_eop, rx_err, crc_absorb, crc_bit, crc_emit;
  wire [15:0] rx_data, status;
  wire tx_grant = tx_request && tx_ready;

  fabric_shifter dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .cfg_bank(2'b01), .ctx_next(1'b0),
      .lines(lines),
      .pulls(pulls),
      .tx_request(tx_request), .tx_grant(tx_grant), .tx_data(tx_data),
      .tx_eop(1'b0), .tx_err(1'b0),
      .rx_request(rx_request), .rx_grant(1'b0), .rx_byte(rx_byte),
      .rx_eop(rx_eop), .rx_err(rx_err), .crc_in(1'b0), .crc_ok(1'b1),
      .out(out), .active(active), .word_pulse(word_pulse),
      .stop_pulse(stop_pulse), .rx_data(rx_data), .status(status),
      .crc_absorb(crc_absorb), .crc_bit(crc_bit), .crc_emit(crc_emit)
  );

  // The word in flight (latched at its grant) and its data bits absorbed.
  reg  [15:0] word = 16'd0;
  reg  [4:0]  taken = 5'd0;
  reg         in_word = 1'b0;
  wire [4:0]  len = {1'b0, len_m1} + 5'd1;
  wire [3:0]  pos = msb ? len_m1 - taken[3:0] : taken[3:0];
  always @(posedge clk) begin
    if (!rst_n) begin
      in_word <= 1'b0;
      taken <= 5'd0;
    end else if (tx_grant) begin
      word <= {8'd0, tx_data};
      in_word <= 1'b1;
      taken <= 5'd0;
    end else if (crc_absorb) begin
      taken <= taken + 5'd1;
    end
    if (rst_n && stop_pulse && !tx_grant)
      in_word <= 1'b0;
  end

  always @(*) if (rst_n && enable) begin
    assert(!crc_emit);
    if (crc_absorb) begin
      assert(in_word && taken < len);
      assert(crc_bit == word[pos]);
    end
    // A word ends with all its data bits taken (the last one may be
    // absorbed in this same cycle: the link is registered).
    if ((tx_grant || stop_pulse) && in_word)
      assert(taken + {4'd0, crc_absorb} == len);
  end

  always @(*) if (rst_n) cover(in_word && burst && pre != 2'd0 && post != 2'd0 && parity != 2'd0 &&
                               taken == len && tx_grant);
endmodule

`default_nettype wire
