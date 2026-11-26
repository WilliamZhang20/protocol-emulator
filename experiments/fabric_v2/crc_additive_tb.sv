`default_nettype none
// CRC tile additive mode against a reference written the textbook way:
// one's complement adds each word and folds the carry back immediately
// (LIN, RFC 1071); two's complement is the sum modulo 2^width. Words go in
// LSB first as the absorb line ticks. Random widths 1-32, word counts,
// init values and edge-heavy words (all ones, zero, one). Checks `value`,
// `ok` against the expected residue, a wrong residue, and the emitted bits
// (the complemented sum, LSB first). Polynomial mode is unchanged: a CRC-16
// of a fixed message is checked before and after additive use.
module crc_additive_tb;
  reg clk = 0, rst_n = 0;
  always #5 clk = !clk;
  reg cfg_we = 0; reg [2:0] cfg_addr = 0; reg [15:0] cfg_data = 0;
  reg absorb = 0, emit = 0, init = 0, data = 0;
  // Lines: 2 absorb, 3 emit, 4 init; level 1 (line 33) data.
  wire [63:0] lines = {30'b0, data, 1'b0, 27'b0, init, emit, absorb, 2'b0};
  wire out, tail_out, ok;
  wire [31:0] value;
  fabric_crc dut(clk, rst_n, 1'b1, cfg_we, cfg_addr, cfg_data, lines, 2'b0, 2'b0, 2'b0,
                 out, tail_out, ok, value);

  integer errors = 0, i, k, n, b, w;
  reg [63:0] sum, m, word, expect_v;
  reg twos, ones_init;

  task automatic write(input [2:0] a, input [15:0] d);
    begin @(negedge clk); cfg_we = 1; cfg_addr = a; cfg_data = d; @(negedge clk); cfg_we = 0; end
  endtask
  task automatic pulse_init;
    begin @(negedge clk); init = 1; @(negedge clk); init = 0; end
  endtask
  task automatic absorb_bit(input bit_v);
    begin @(negedge clk); absorb = 1; data = bit_v; @(negedge clk); absorb = 0; end
  endtask

  // CRC-16/ARC style check of polynomial mode: absorb "123456789" LSB
  // first is not ARC's reflected form, so compare against a bit-serial
  // software LFSR of the same shape instead.
  function automatic [15:0] lfsr16(input [71:0] msg);
    reg [15:0] r; integer j; reg fb;
    begin
      r = 16'h0000;
      for (j = 0; j < 72; j = j + 1) begin
        fb = r[15] ^ msg[j];
        r = {r[14:0], 1'b0} ^ (fb ? 16'h8005 : 16'h0000);
      end
      lfsr16 = r;
    end
  endfunction
  task automatic poly_check;
    reg [71:0] msg; integer j;
    begin
      msg = 72'h393837363534333231;
      write(3'd0, 16'h8005); write(3'd1, 16'h0000);
      write(3'd6, {6'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 5'd15});   // width 16, init 0, not additive
      pulse_init;
      for (j = 0; j < 72; j = j + 1) absorb_bit(msg[j]);
      @(negedge clk);
      if (value[15:0] !== lfsr16(msg)) begin
        errors = errors + 1; $display("FAIL polynomial mode: %h, expected %h", value[15:0], lfsr16(msg));
      end
    end
  endtask

  initial begin
    // Lines: absorb 2, data level 1; emit 3, init line 4.
    repeat (3) @(negedge clk); rst_n = 1;
    write(3'd4, {5'd1, 6'd2});
    write(3'd5, {5'd4, 6'd3});
    poly_check;
    for (i = 0; i < 400; i = i + 1) begin
      w = (i % 5 == 0) ? 8 : (i % 5 == 1) ? 16 : 1 + $urandom % 32;
      twos = $urandom % 2;
      ones_init = ($urandom % 4) == 0;
      n = 1 + $urandom % 12;
      m = (64'd1 << w) - 1;
      write(3'd6, {6'd0, twos, 1'b1, 1'b0, 1'b0, ones_init, 5'(w - 1)});
      pulse_init;
      sum = ones_init ? m : 0;
      for (k = 0; k < n; k = k + 1) begin
        case ($urandom % 5)
          0: word = m;
          1: word = 0;
          2: word = 1;
          default: word = {$urandom, $urandom} & m;
        endcase
        sum = sum + word;
        if (twos) sum = sum & m;
        else if (sum > m) sum = (sum & m) + 1;
        for (b = 0; b < w; b = b + 1) absorb_bit(word[b]);
      end
      expect_v = sum;
      // Residue: the expected sum (ok), then one bit off (not ok).
      write(3'd2, expect_v[15:0]); write(3'd3, expect_v[31:16]);
      repeat (2) @(negedge clk);
      if ((value & m) !== expect_v[31:0] || !ok) begin
        errors = errors + 1;
        if (errors < 12) $display("FAIL width %0d %s, %0d words: value %h ok %b, expected %h",
                                  w, twos ? "two's" : "one's", n, value & m, ok, expect_v);
      end
      write(3'd2, expect_v[15:0] ^ 16'h1);
      repeat (2) @(negedge clk);
      if (ok) begin errors = errors + 1; $display("FAIL wrong residue accepted"); end
      // Emit: out is the complemented sum, LSB first.
      for (b = 0; b < w; b = b + 1) begin
        @(negedge clk); #1;
        if (out !== !expect_v[b]) begin
          errors = errors + 1;
          if (errors < 12) $display("FAIL emit bit %0d of width %0d: out %b, sum %h", b, w, out, expect_v);
        end
        emit = 1; @(negedge clk); emit = 0;
      end
    end
    poly_check;
    if (errors == 0) $display("crc additive: PASS (400 sums, emit and residue checks; polynomial mode unchanged)");
    else $fatal(1, "crc additive: %0d FAIL", errors);
    $finish;
  end
endmodule
`default_nettype wire
