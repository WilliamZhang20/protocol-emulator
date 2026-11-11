`default_nettype none

// Bit coder, Manchester transmit: a cycle invariant on the shifter's output
// alone. The shift line ticks every half bit. Counting ticks from the
// moment the tile starts from idle, every odd tick is the middle of a bit
// and must flip the line (each bit is its complement, then itself), for
// any word length, bit order, idle level, FIFO data and timing, a CRC
// tail of 0-3 bits from an arbitrary CRC bit stream, optional stuffing,
// across burst words and frames started back to back. The harness never
// reads the tile's own half-bit state.
module fabric_shifter_manchester_properties (input wire clk);   // one solver step = one clock cycle
  reg [3:0] t = 4'd0;
  always @(posedge clk) if (t != 4'd15) t <= t + 4'd1;
  wire rst_n = t >= 4'd2;

  (* anyconst *) reg [2:0] n;           // stuffing (0: none)
  (* anyconst *) reg [3:0] len_m1;
  (* anyconst *) reg       msb;
  (* anyconst *) reg [1:0] tail;
  (* anyconst *) reg       idle;

  (* anyseq *) reg       tick;
  (* anyseq *) reg       tx_ready;
  (* anyseq *) reg [7:0] tx_data;
  (* anyseq *) reg       tx_eop;
  (* anyseq *) reg       crc_in;

  reg        cfg_we;
  reg [2:0]  cfg_addr;
  reg [15:0] cfg_data;
  always @(*) begin
    cfg_we = rst_n && t <= 4'd6;
    cfg_addr = 3'd0;
    cfg_data = 16'd0;
    case (t)
      4'd2: begin cfg_addr = 3'd1; cfg_data = {idle, 2'b00, msb, 8'd0, len_m1}; end
      4'd3: begin cfg_addr = 3'd2; cfg_data = 16'd2; end            // shift: line 2
      4'd4: begin cfg_addr = 3'd3; cfg_data = 16'd1 << 11; end      // auto pull
      4'd5: begin cfg_addr = 3'd5; cfg_data = {1'b1, 4'd0, tail, 6'd0, n}; end  // Manchester
      4'd6: begin cfg_addr = 3'd4; cfg_data = 16'd1 << 5; end       // burst, end on empty
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
      .tx_eop(tx_eop), .tx_err(1'b0),
      .rx_request(rx_request), .rx_grant(1'b0), .rx_byte(rx_byte),
      .rx_eop(rx_eop), .rx_err(rx_err), .crc_in(crc_in),
      .out(out), .active(active), .word_pulse(word_pulse),
      .stop_pulse(stop_pulse), .rx_data(rx_data), .status(status),
      .crc_absorb(crc_absorb), .crc_bit(crc_bit), .crc_emit(crc_emit)
  );

  // second: the bit's second half is on the line (counted from the start
  // from idle, one flip per tick while active).
  reg was_active = 1'b0, ticked = 1'b0, second = 1'b0, last = 1'b0;
  reg [3:0] mids = 4'd0;
  wire fresh_bit = active && !was_active;
  wire step = active && was_active && ticked;
  always @(posedge clk) begin
    was_active <= rst_n && active;
    ticked     <= enable && tick && active;
    last       <= out;
    if (fresh_bit)
      second <= 1'b0;
    else if (step) begin
      second <= !second;
      if (!second && mids != 4'd15)
        mids <= mids + 4'd1;
    end
  end

  // The tick that made this cycle's line was a mid-bit tick: the line flipped.
  always @(*) if (rst_n && enable && step && !second) assert(out != last);

  always @(*) if (rst_n) cover(mids == 4'd10 && tail == 2'd2 && n == 3'd0);
  always @(*) if (rst_n) cover(step && second && n == 3'd2 && out != last);
endmodule

`default_nettype wire
