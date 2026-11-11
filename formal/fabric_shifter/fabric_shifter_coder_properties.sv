`default_nettype none

// Bit coder, transmit side: the stuffing rule as a cycle invariant on the
// shifter's output alone. The harness watches the line (NRZI off) and
// counts the bits it carries, with no access to the tile's own run counter:
// for any stuff length N (1-7), either run kind, word length, bit order,
// FIFO data and timing, and a CRC tail of 0-3 bits from an arbitrary CRC
// bit stream, no run is ever longer than N, across burst words, frames
// started back to back, and the tail. Runs restart only when the tile
// starts from idle.
module fabric_shifter_coder_properties (input wire clk);   // one solver step = one clock cycle
  reg [3:0] t = 4'd0;
  always @(posedge clk) if (t != 4'd15) t <= t + 4'd1;
  wire rst_n = t >= 4'd2;

  (* anyconst *) reg [2:0] n;           // stuff after n equal bits / ones
  (* anyconst *) reg       ones;
  (* anyconst *) reg [3:0] len_m1;
  (* anyconst *) reg       msb;
  (* anyconst *) reg [1:0] tail;
  (* anyconst *) reg       idle;
  always @(*) assume(n != 3'd0);

  (* anyseq *) reg       tick;
  (* anyseq *) reg       tx_ready;
  (* anyseq *) reg [7:0] tx_data;
  (* anyseq *) reg       tx_eop;
  (* anyseq *) reg       crc_in;

  // Configuration, one register a cycle, then the fabric runs.
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
      4'd5: begin cfg_addr = 3'd5; cfg_data = {5'd0, tail, 5'd0, ones, n}; end   // tail [14:9]
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

  // A new bit is on the line in the cycle after the tile starts from idle
  // (the run restarts) and after every tick while it stays active.
  reg       was_active = 1'b0, ticked = 1'b0;
  reg [3:0] run = 4'd0;
  reg       last = 1'b0;
  wire fresh_bit = active && !was_active;
  wire next_bit  = active && was_active && ticked;
  wire [3:0] run_now = fresh_bit ? (ones ? {3'd0, out} : 4'd1) :
                       !next_bit ? run :
                       ones ? (out ? run + 4'd1 : 4'd0) :
                       (out == last ? run + 4'd1 : 4'd1);
  always @(posedge clk) begin
    was_active <= rst_n && active;
    ticked     <= enable && tick && active;
    if (fresh_bit || next_bit) begin
      run  <= run_now;
      last <= out;
    end
  end

  always @(*) if (rst_n && enable) assert(run_now <= {1'b0, n});

  // The rule is exercised: a run reaches n and the next bit breaks it.
  always @(*) if (rst_n) cover(next_bit && run == {1'b0, n} && n == 3'd3 && !ones &&
                               out != last);
  always @(*) if (rst_n) cover(next_bit && run == {1'b0, n} && n == 3'd2 && ones && !out);
endmodule

`default_nettype wire
