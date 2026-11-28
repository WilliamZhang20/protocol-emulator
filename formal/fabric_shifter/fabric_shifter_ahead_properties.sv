`default_nettype none

// End lookahead (burst [13]): a receiving burst whose end level comes after
// the last word (USB's SE0). For any word length of 2-4 bits, any start,
// sample, data and end-level timing, and a host that takes every push:
//  - every completed word is pushed exactly once, in order: words pulsed
//    minus bytes pushed is 0 or 1 (at most one word held), and 0 the clock
//    after the tile stops;
//  - a pushed byte is the word it stands for (the tile's last completed
//    word, rx_data, since at most one word is outstanding);
//  - a byte tagged eop is pushed only as the frame ends: the clock after
//    its last word ends (the end level seen during it; a new frame may
//    start on that clock) or after the lookahead stop (the end level after
//    it), with no word outstanding: it is the packet's last byte.
// The harness reads only the tile's ports.
module fabric_shifter_ahead_properties (input wire clk);   // one solver step = one clock cycle
  reg [3:0] t = 4'd0;
  always @(posedge clk) if (t != 4'd15) t <= t + 4'd1;
  wire rst_n = t >= 4'd2;

  (* anyconst *) reg [3:0] len_m1;
  always @(*) assume(len_m1 >= 4'd1 && len_m1 <= 4'd3);   // lookahead needs words of two bits or more

  (* anyseq *) reg start_l, tick, din, end_l;

  reg        cfg_we;
  reg [2:0]  cfg_addr;
  reg [15:0] cfg_data;
  always @(*) begin
    cfg_we = rst_n && t <= 4'd5;
    cfg_addr = 3'd0;
    cfg_data = 16'd0;
    case (t)
      4'd2: begin cfg_addr = 3'd1; cfg_data = {12'd0, len_m1}; end
      4'd3: begin cfg_addr = 3'd2; cfg_data = 16'd2 | (16'd2 << 6); end          // shift and sample: line 2
      4'd4: begin cfg_addr = 3'd3; cfg_data = 16'd1 | (16'd1 << 6) | (16'd1 << 12); end  // start line 1, in level 33, auto push
      4'd5: begin cfg_addr = 3'd4; cfg_data = 16'd2 | (16'd1 << 5) | (16'd1 << 13); end  // end level 34, burst, lookahead
      default: ;
    endcase
  end
  wire enable = t >= 4'd6;
  wire [63:0] lines = {29'd0, end_l, din, 2'b0, 28'd0, enable && tick, enable && start_l, 1'b0};   // levels 33 din, 34 end

  wire tx_request, rx_request, out, active, word_pulse, stop_pulse, pulls;
  wire [7:0] rx_byte;
  wire rx_eop, rx_err, crc_absorb, crc_bit, crc_emit;
  wire [15:0] rx_data, status;

  fabric_shifter dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .cfg_bank(2'b01), .ctx_next(1'b0),
      .lines(lines),
      .pulls(pulls),
      .tx_request(tx_request), .tx_grant(1'b0), .tx_data(8'd0),
      .tx_eop(1'b0), .tx_err(1'b0),
      .rx_request(rx_request), .rx_grant(rx_request), .rx_byte(rx_byte),
      .rx_eop(rx_eop), .rx_err(rx_err), .crc_in(1'b0),
      .out(out), .active(active), .word_pulse(word_pulse),
      .stop_pulse(stop_pulse), .rx_data(rx_data), .status(status),
      .crc_absorb(crc_absorb), .crc_bit(crc_bit), .crc_emit(crc_emit)
  );

  // Words pulsed minus bytes pushed (a push shows as rx_request: the host
  // takes it at once, so each push is one clock of request).
  reg [2:0] diff = 3'd0;
  reg stopped = 1'b0, worded = 1'b0;
  reg [3:0] words = 4'd0, eops = 4'd0;
  wire [2:0] diff_now = diff - {2'd0, rx_request};
  always @(posedge clk) begin
    if (!rst_n) begin
      diff <= 3'd0; stopped <= 1'b0; worded <= 1'b0;
    end else begin
      diff <= diff + {2'd0, word_pulse} - {2'd0, rx_request};
      stopped <= stop_pulse;
      worded <= word_pulse;
      if (word_pulse && words != 4'd15) words <= words + 4'd1;
      if (rx_request && rx_eop && eops != 4'd15) eops <= eops + 4'd1;
    end
  end

  always @(*) if (rst_n && enable) begin
    assert(diff_now == 3'd0 || diff_now == 3'd1);
    if (stopped) assert(diff_now == 3'd0);
    if (rx_request) assert(rx_byte == rx_data[7:0]);
    if (rx_request && rx_eop) assert((stopped || worded) && diff_now == 3'd0);
  end

  // A packet of two words or more ended by the end level after its last word.
  always @(*) if (rst_n) cover(eops == 4'd1 && words >= 4'd3 && len_m1 == 4'd1);
  always @(*) if (rst_n) cover(eops == 4'd2);
endmodule

`default_nettype wire
