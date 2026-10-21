`default_nettype none

// Shifter tile against an independently written frame model:
//  * while active, `out` is exactly the frame bit at the model's index
//    (pre / data in either bit order / parity / post, with lead mode),
//    including frames restarted gaplessly in the cycle the last one ends;
//  * with the input line looped back to `out`, a frame whose data bits were
//    all sampled reproduces the transmitted word in rx_data and the RX push;
//  * burst mode: between words the frame jumps from the last data bit to
//    the next word's first data bit (no pre/parity/post), the word in which
//    the end line was seen (or the FIFO ran dry) is the last, and every
//    word pulses `word` and is pushed;
//  * byte tags: a word pulled tagged eop ends a burst (when enabled), a
//    word pulled tagged err is sent with its parity bit inverted; RX
//    pushes are tagged eop exactly at the end of a burst frame and, with
//    the frame fully sampled in loopback, err exactly when its parity was
//    injected (a clean frame is never flagged);
//  * an abort line drops the frame in progress: the tile goes idle with no
//    word pulse and no push, and starts nothing while the line is high;
//  * FIFO handshakes never drop or invent bytes, and overrun is flagged.
module fabric_shifter_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [2:0]  cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [63:0] lines_any;
  (* anyseq *) reg        tx_ready;
  (* anyseq *) reg [7:0]  tx_data;
  (* anyseq *) reg        tx_eop, tx_err;
  (* anyseq *) reg        rx_ready;
  wire tx_request, rx_request, out, active, word_pulse, stop_pulse;
  wire [7:0] rx_byte;
  wire rx_eop, rx_err, pulls;
  wire [15:0] rx_data, status;
  wire tx_grant = tx_request && tx_ready;
  wire rx_grant = rx_request && rx_ready;

  // Shadow configuration, written only while the tile is idle and not
  // starting (the controller's programming rule).
  reg [15:0] frame_s = 16'd0, data_s = 16'd0;
  reg [11:0] step_s = 12'd0;
  reg [12:0] io_s = 13'd0;
  reg [12:0] burst_s = 13'd0;

  // Loop the selected input level line back to the shifter's own output.
  wire [5:0] in_sel = {1'b1, io_s[10:6]};
  wire [63:0] lines_raw = {lines_any[63:2], 1'b1, 1'b0};
  wire [63:0] lines = (lines_raw & ~(64'd1 << in_sel)) | ({63'd0, out} << in_sel);

  fabric_shifter dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .cfg_bank(2'b01), .ctx_next(1'b0),  // contexts: checked in fabric_logic
      .lines(lines),
      .pulls(pulls),
      .tx_request(tx_request), .tx_grant(tx_grant), .tx_data(tx_data),
      .tx_eop(tx_eop), .tx_err(tx_err),
      .rx_request(rx_request), .rx_grant(rx_grant), .rx_byte(rx_byte),
      .rx_eop(rx_eop), .rx_err(rx_err),
      .out(out), .active(active), .word_pulse(word_pulse),
      .stop_pulse(stop_pulse), .rx_data(rx_data), .status(status)
  );

  wire trigger = io_s[5:0] != 6'd0 ? lines[io_s[5:0]] : io_s[11];
  wire abort_m = lines[burst_s[12:7]];
  wire run_m = enable && !abort_m;
  always @(*) if (rst_n && cfg_we && cfg_addr != 3'd0)
    assume(!active && !(run_m && trigger && (!io_s[11] || tx_grant)));
  always @(*) if (rst_n && cfg_we) assume(cfg_addr <= 3'd4);

  wire [4:0] len  = {1'b0, frame_s[3:0]} + 5'd1;
  wire [1:0] npre = frame_s[5:4];
  wire [1:0] npost = frame_s[8:7];
  wire has_par = frame_s[11:10] != 2'd0;
  wire lead = frame_s[13];
  wire end_on_sample = frame_s[14];
  wire [4:0] total = {3'd0, npre} + len + {4'd0, has_par} + {3'd0, npost};

  // Frame as a bit vector, built position by position; `bad` inverts the
  // parity bit (an injected error).
  reg [15:0] word;     // word latched at start
  reg        w_eop = 1'b0, w_err = 1'b0;   // its tags (pulled words only)
  function automatic [31:0] build_frame(input [15:0] w, input bad);
    integer i, pos;
    reg par;
    begin
      build_frame = 32'd0;
      par = frame_s[11] ^ bad;
      pos = 0;
      for (i = 0; i < 3; i = i + 1)
        if (i < npre) begin build_frame[pos] = frame_s[6]; pos = pos + 1; end
      for (i = 0; i < 16; i = i + 1)
        if (i < len) begin
          build_frame[pos] = frame_s[12] ? w[(len - 5'd1 - i[4:0]) & 5'd15] : w[i];
          par = par ^ w[i];
          pos = pos + 1;
        end
      if (has_par) begin build_frame[pos] = par; pos = pos + 1; end
      for (i = 0; i < 3; i = i + 1)
        if (i < npost) begin build_frame[pos] = frame_s[9]; pos = pos + 1; end
    end
  endfunction

  reg [4:0]  r_idx = 5'd0;
  reg        r_lead = 1'b0;
  reg        r_active = 1'b0;
  reg        r_end_seen = 1'b0;
  reg [1:0]  burst_words = 2'd0;    // words continued into, saturating
  reg [15:0] r_sampled = 16'd0;
  wire shift_evt  = r_active && lines[step_s[5:0]];
  wire sample_now = r_active && lines[step_s[11:6]] && !r_lead;
  wire [31:0] frame_bits = build_frame(word, w_err);
  wire in_data = r_idx >= {3'd0, npre} && r_idx < {3'd0, npre} + len;
  wire [4:0] data_i = r_idx - {3'd0, npre};
  wire [3:0] data_pos = frame_s[12] ? (len[3:0] - 4'd1 - data_i[3:0]) : data_i[3:0];
  wire at_last = r_idx == total - 5'd1;
  wire end_evt = end_on_sample ? sample_now : (shift_evt && !r_lead);
  wire end_line = lines[{1'b1, burst_s[4:0]}];
  // Burst: the word continues into the next one at its last data bit.
  wire burst_go = run_m && burst_s[5] && r_idx == {3'd0, npre} + len - 5'd1 &&
                  end_evt && !(r_end_seen || end_line || (burst_s[6] && w_eop));
  wire burst_pull = burst_go && io_s[11];
  wire expect_next = burst_go && (!io_s[11] || tx_grant);
  wire expect_done = run_m && r_active && at_last && end_evt && !expect_next;
  wire start_pulse = run_m && (!r_active || expect_done) && trigger &&
                     (!io_s[11] || tx_grant);
  wire [15:0] len_mask = 16'hffff >> (5'd16 - len);
  wire [15:0] sampled_now = r_sampled |
      ((sample_now && in_data) ? (16'd1 << data_pos) : 16'd0);
  // Parity and post positions sampled in this frame.
  reg  [31:0] r_tail = 32'd0;
  wire [4:0]  tail_start = {3'd0, npre} + len;
  wire [31:0] tail_mask = ((32'd1 << total) - 32'd1) & ~((32'd1 << tail_start) - 32'd1);
  wire [31:0] tail_now = r_tail |
      ((sample_now && r_idx >= tail_start) ? (32'd1 << r_idx) : 32'd0);

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      frame_s <= 16'd0; step_s <= 12'd0; data_s <= 16'd0; io_s <= 13'd0;
      burst_s <= 13'd0; word <= 16'd0; w_eop <= 1'b0; w_err <= 1'b0;
      r_idx <= 5'd0; r_lead <= 1'b0; r_sampled <= 16'd0;
      r_active <= 1'b0; r_end_seen <= 1'b0; burst_words <= 2'd0; r_tail <= 32'd0;
    end else begin
      if (start_pulse)
        burst_words <= 2'd0;
      else if (expect_next && burst_words != 2'd3)
        burst_words <= burst_words + 2'd1;
      if (cfg_we) begin
        case (cfg_addr)
          3'd0: if (!active && !(start_pulse && io_s[11])) data_s <= cfg_data;
          3'd1: frame_s <= cfg_data;
          3'd2: step_s <= cfg_data[11:0];
          3'd3: io_s <= cfg_data[12:0];
          default: burst_s <= cfg_data[12:0];
        endcase
      end
      if ((start_pulse || expect_next) && io_s[11])
        data_s <= {8'd0, tx_data};   // a pulled byte replaces the data word
      if (!run_m)
        r_active <= 1'b0;
      else if (start_pulse)
        r_active <= 1'b1;
      else if (expect_done)
        r_active <= 1'b0;
      if (start_pulse || expect_next) begin
        w_eop <= io_s[11] && tx_eop;
        w_err <= io_s[11] && tx_err;
      end
      if (start_pulse) begin
        // A data write in the start cycle is the word sent (unless pulling).
        word <= io_s[11] ? {8'd0, tx_data} :
                (cfg_we && cfg_addr == 3'd0 && !active) ? cfg_data : data_s;
        r_idx <= 5'd0; r_lead <= lead; r_sampled <= 16'd0; r_end_seen <= 1'b0;
        r_tail <= 32'd0;
      end else if (expect_next) begin
        word <= io_s[11] ? {8'd0, tx_data} : data_s;
        r_idx <= {3'd0, npre}; r_lead <= lead; r_sampled <= 16'd0;
      end else if (r_active) begin
        if (end_line)
          r_end_seen <= 1'b1;
        if (sample_now && in_data)
          r_sampled <= sampled_now;
        r_tail <= tail_now;
        if (shift_evt) begin
          if (r_lead) r_lead <= 1'b0;
          else if (!at_last) r_idx <= r_idx + 5'd1;
        end
      end
    end
  end

  reg past_valid = 1'b0;
  reg past_check, past_push_check, past_overrun_case, past_rx_hold;
  reg past_eop_expect, past_err_check, past_err_expect;
  reg [15:0] past_word;
  always @(posedge clk) begin
    past_valid <= rst_n;
    past_check <= word_pulse && (sampled_now & len_mask) == len_mask;
    past_push_check <= word_pulse && io_s[12];
    past_overrun_case <= word_pulse && io_s[12] && rx_request && !rx_grant;
    past_rx_hold <= enable && rx_request && !rx_grant;
    past_eop_expect <= burst_s[5] && expect_done;
    past_err_check <= expect_done && !burst_s[5] &&
                      (sampled_now & len_mask) == len_mask &&
                      (tail_now & tail_mask) == tail_mask;
    past_err_expect <= has_par && w_err;
    past_word <= word;
  end

  always @(*) begin
    if (rst_n) begin
      assert(active == r_active);
      if (active && enable) assert(out == frame_bits[r_idx]);
      if (!active) assert(out == frame_s[15]);
      assert(word_pulse == (expect_done || expect_next));
      assert(stop_pulse == (expect_done && !start_pulse));
      if (tx_request) assert(!active || expect_done || burst_go);
      if (burst_pull) assert(tx_request);
      if (active) assert(r_idx < total);
    end
  end

  always @(posedge clk) begin
    if (rst_n && past_valid && enable) begin
      if (past_check && past_push_check && len >= 5'd8)
        assert(rx_request && rx_byte == past_word[7:0]);
      if (past_check && !active)
        assert((rx_data & len_mask) == (past_word & len_mask));
      if (past_overrun_case) assert(status[14]);
      if (past_rx_hold) assert(rx_request);
      if (past_push_check) assert(rx_eop == past_eop_expect);
      if (past_push_check && past_err_check) assert(rx_err == past_err_expect);
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover(word_pulse && has_par && npre == 2'd1 && npost == 2'd1 && len == 5'd8);
      cover(word_pulse && lead && end_on_sample && frame_s[12]);
      cover(word_pulse && !stop_pulse && io_s[11]);   // gapless restart
      cover(expect_done && burst_s[6] && w_eop && burst_words == 2'd1);  // eop ends
      cover(past_push_check && past_err_check && rx_err);  // injected, caught
      cover(r_active && abort_m && enable && burst_s[12:7] != 6'd0);  // aborted
      // A three-word pulled burst framed by a start and a stop bit.
      cover(expect_done && burst_s[5] && io_s[11] && npre == 2'd1 &&
            npost == 2'd1 && has_par && burst_words == 2'd2);
    end
  end
endmodule

`default_nettype wire
