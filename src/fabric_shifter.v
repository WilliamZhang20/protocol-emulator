`default_nettype none

// Spatial fabric shifter tile. Emits and captures one framed word:
//   [pre bits][data bits][optional parity][post bits]
// The frame index advances on the shift line; the input line is captured on
// the sample line. Data bits land in rx_data at their natural bit position,
// so an 8-bit word is always rx_data[7:0] regardless of bit order. Parity and
// post bits (UART stop, I2C ACK) are captured into post_cap, newest in bit 0.
//
// Registers (16-bit, written by the controller):
//   0 data   transmit word (ignored while active)
//   1 frame  [3:0] len-1  [5:4] pre count  [6] pre value
//            [8:7] post count  [9] post value
//            [11:10] parity: 0 none, 1 even, 2 odd
//            [12] msb first  [13] lead (first shift presents bit 0)
//            [14] end on sample  [15] idle level
//   2 step   [5:0] shift line  [11:6] sample line
//   3 io     [5:0] start line  [10:6] input level (signal space 32-63)
//            [11] auto pull TX FIFO  [12] auto push RX FIFO
//   4 burst  [4:0] burst-end level (signal space 32-63)  [5] burst mode
//            [6] a pulled byte tagged eop also ends the burst
//            [12:7] abort line: while it is high the tile is idle and a
//            frame in progress is dropped without a word pulse or push
//            (e.g. carrier loss in the middle of a word); 0 never aborts
//
// FIFO bytes carry tags. TX: a byte pulled tagged err is sent with its
// parity bit inverted (error injection). RX: an auto-pushed byte is tagged
// eop when it is the last word of a burst frame, and err when its frame
// ended with a wrong parity bit or a wrong post bit.
//
// A frame starts when the start line is high, or (start line 0 with auto
// pull) whenever the TX FIFO grants a byte. A new frame may start in the
// same cycle the previous one ends, so streams are gapless. `word` pulses at
// every word end; `stop` pulses when the shifter actually goes idle.
//
// Burst mode: where a word's last data bit would end (the same shift or
// sample event that ends a frame), the next word starts directly at its
// first data bit, so pre, parity and post bits appear only around the
// whole burst. The next word is pulled from the TX FIFO (auto pull) or is
// the data register again. The word during which the burst-end line has
// been high (or auto pull finds the FIFO empty at its end, or, with [6],
// the word was pulled with the eop tag) is the last one; parity covers
// that word only.
module fabric_shifter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [2:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [1:0]  cfg_bank,      // contexts a write goes to
    input  wire        ctx_next,  // context active from the next cycle
    input  wire [63:0] lines,
    output wire        pulls,       // auto pull: owns its TX FIFO channel
    output wire        tx_request,
    input  wire        tx_grant,
    input  wire [7:0]  tx_data,
    input  wire        tx_eop,
    input  wire        tx_err,
    output wire        rx_request,
    input  wire        rx_grant,
    output wire [7:0]  rx_byte,
    output wire        rx_eop,
    output wire        rx_err,
    output wire        out,
    output wire        active,
    output wire        word_pulse,
    output wire        stop_pulse,
    output wire [15:0] rx_data,
    output wire [15:0] status
);
  reg [15:0] tx_word;
  // Each frame bit is read through one view only: the boundary fields and
  // the idle level from `frame_next` (precomputed below), the rest from
  // `frame`; the other view's copy of those bits is unused, not dead.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] frame, frame_next;
  /* verilator lint_on UNUSEDSIGNAL */
  wire [11:0] step;
  wire [12:0] io;
  wire [12:0] burst;
  reg [15:0] rx_word;
  reg [3:0]  post_cap;
  reg        par_cap, post_wrong;    // RX framing check (see below)
  reg [4:0]  index;
  reg        active_r;
  reg        lead_wait;
  reg        push_pending;
  reg [7:0]  push_byte;
  reg        push_eop, push_err;
  reg        overrun;
  reg        out_r;
  reg        burst_end_seen;
  reg        word_eop;           // the word in flight was pulled tagged eop
  reg        word_err;           // ... or tagged err: invert its parity bit

  wire [4:0] pre_n     = {3'b0, frame[5:4]};
  wire       pre_val   = frame[6];
  wire       post_val  = frame[9];
  wire       odd_parity = frame[11];
  wire       msb_first = frame[12];
  wire       lead      = frame[13];
  wire       end_on_sample = frame[14];
  wire [5:0] start_sel = io[5:0];
  wire       auto_pull = io[11];
  wire       auto_push = io[12];
  wire       burst_mode = burst[5];
  wire       abort = lines[burst[12:7]];
  wire       run   = enable && !abort;

  // Frame boundaries depend only on the frame register, so they are
  // registered alongside it (computed from the value active next cycle,
  // including a write or a context switch) instead of passing through an
  // adder chain every cycle.
  wire [3:0]  len_m1_next = frame_next[3:0];
  wire [1:0]  pre_next    = frame_next[5:4];
  wire [1:0]  post_next   = frame_next[8:7];
  wire [1:0]  parity_next = frame_next[11:10];
  wire        idle_next   = frame_next[15];
  wire [4:0]  len_next   = {1'b0, len_m1_next} + 5'd1;
  wire [4:0]  data_end_next = {3'b0, pre_next} + len_next;
  wire [4:0]  par_end_next  = data_end_next + {4'b0, parity_next != 2'd0};
  reg  [4:0]  data_end, par_end, last_index, data_last;
  reg  [15:0] len_mask;
  always @(posedge clk) begin
    if (!rst_n) begin
      data_end   <= 5'd1;
      par_end    <= 5'd1;
      last_index <= 5'd0;
      data_last  <= 5'd0;
      len_mask   <= 16'd1;
    end else begin
      data_end   <= data_end_next;
      data_last  <= data_end_next - 5'd1;
      par_end    <= par_end_next;
      last_index <= par_end_next + {3'b0, post_next} - 5'd1;
      len_mask   <= 16'hffff >> (5'd16 - len_next);
    end
  end

  // The frame bit at position i of word w.
  function automatic frame_bit_at(input [4:0] i, input [15:0] w);
    reg [3:0] raw;
    begin
      raw = i[3:0] - pre_n[3:0];
      if (i < pre_n)
        frame_bit_at = pre_val;
      else if (i < data_end)
        frame_bit_at = w[msb_first ? (frame[3:0] - raw) : raw];
      else if (i < par_end)
        frame_bit_at = (^(w & len_mask)) ^ odd_parity ^ word_err;
      else
        frame_bit_at = post_val;
    end
  endfunction

  wire in_pre  = index < pre_n;
  wire in_data = !in_pre && index < data_end;
  wire [3:0] data_pos_raw = index[3:0] - pre_n[3:0];
  wire [3:0] data_pos = msb_first ? (frame[3:0] - data_pos_raw) : data_pos_raw;

  wire shift_evt  = active_r && lines[step[5:0]];
  wire sample_now = active_r && lines[step[11:6]] && !lead_wait;
  wire end_evt = end_on_sample ? sample_now : (shift_evt && !lead_wait);
  // `>=` rather than `==`: if the framing changes under a frame in progress
  // (a context switch), the frame still ends at its next end event.
  wire at_last = index >= last_index;
  wire [31:0] levels = lines[63:32];
  // A burst continues past this word's last data bit unless the end line
  // has been seen; with auto pull it also needs the next byte.
  wire burst_want = run && burst_mode && index == data_last && end_evt &&
                    !(burst_end_seen || levels[burst[4:0]] || (burst[6] && word_eop));
  wire burst_next = burst_want && (!auto_pull || tx_grant);
  wire frame_end = run && at_last && end_evt;
  wire done = frame_end && !burst_next;
  wire trigger = start_sel != 6'd0 ? lines[start_sel] : auto_pull;
  wire start = run && (!active_r || done) && trigger &&
               (!auto_pull || tx_grant);
  wire in_bit = levels[io[10:6]];
  wire [15:0] data_bit_mask = 16'd1 << data_pos;
  wire [15:0] rx_next = (sample_now && in_data) ?
      ((rx_word & ~data_bit_mask) | (in_bit ? data_bit_mask : 16'd0)) :
      rx_word;

  // Received framing check by bit position, including this cycle's sample
  // (any number of samples per bit): the last parity sample must match the
  // data, and every post sample must equal the post value. The parity bit
  // comes after the data, so by then rx_word holds every data bit; using it
  // instead of rx_next keeps the pin and the data mux off this path.
  wire post_sample = sample_now && !in_pre && !in_data;
  wire at_parity   = index < par_end;            // past the data bits
  wire par_now  = (post_sample && at_parity) ? in_bit : par_cap;
  wire post_bad = post_wrong || (post_sample && !at_parity && in_bit != post_val);
  wire par_bad  = frame[11:10] != 2'd0 &&
                  par_now != ((^(rx_word & len_mask)) ^ odd_parity);

  // Requested from frame_end, not done, so the grant never feeds back into
  // its own request; the two differ only when burst_want already requests.
  assign tx_request = auto_pull &&
      (burst_want || (run && (!active_r || frame_end) && trigger));
  assign rx_request = push_pending;
  assign rx_byte    = push_byte;
  assign rx_eop     = push_eop;
  assign rx_err     = push_err;
  assign out        = out_r;
  assign active     = active_r;
  assign pulls      = enable && auto_pull;
  assign word_pulse = done || burst_next;
  assign stop_pulse = done && !start;
  assign rx_data    = rx_word;
  assign status = {active_r, overrun, push_pending, 9'b0, post_cap};

  config_bank #(.WIDTH(16)) frame_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 3'd1), .write_bank(cfg_bank), .data(cfg_data),
      .ctx_next(ctx_next), .value(frame), .next(frame_next));
  config_bank #(.WIDTH(12)) step_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 3'd2), .write_bank(cfg_bank), .data(cfg_data[11:0]),
      .ctx_next(ctx_next), .value(step), .next());
  config_bank #(.WIDTH(13)) io_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 3'd3), .write_bank(cfg_bank), .data(cfg_data[12:0]),
      .ctx_next(ctx_next), .value(io), .next());
  config_bank #(.WIDTH(13)) burst_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 3'd4), .write_bank(cfg_bank), .data(cfg_data[12:0]),
      .ctx_next(ctx_next), .value(burst), .next());

  // The output is a register so downstream glue and tiles start their
  // paths at a flop. Each candidate (new frame, advance, hold) is
  // precomputed from registers; the shift line only selects among them.
  wire [15:0] start_word = auto_pull ? {8'd0, tx_data} :
      (cfg_we && cfg_addr == 3'd0 && !active_r) ? cfg_data : tx_word;
  wire [15:0] burst_word = auto_pull ? {8'd0, tx_data} : tx_word;
  wire advance = shift_evt && !lead_wait && !at_last;
  wire bit_start = frame_bit_at(5'd0, start_word);
  wire bit_burst = frame_bit_at(pre_n, burst_word);
  wire bit_next  = frame_bit_at(index + 5'd1, tx_word);
  wire bit_hold  = frame_bit_at(index, tx_word);
  always @(posedge clk) begin
    if (!rst_n)
      out_r <= 1'b0;
    else if (start)
      out_r <= bit_start;
    else if (burst_next)
      out_r <= bit_burst;
    else if (!active_r || done || !run)
      out_r <= idle_next;
    else
      out_r <= advance ? bit_next : bit_hold;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      tx_word <= 16'd0;
    end else if ((start || burst_next) && auto_pull) begin
      tx_word <= {8'd0, tx_data};
    end else if (cfg_we && cfg_addr == 3'd0 && !active_r) begin
      tx_word <= cfg_data;
    end
  end

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      rx_word      <= 16'd0;
      post_cap     <= 4'd0;
      par_cap      <= 1'b0;
      post_wrong   <= 1'b0;
      index        <= 5'd0;
      active_r     <= 1'b0;
      lead_wait    <= 1'b0;
      push_pending <= 1'b0;
      push_byte    <= 8'd0;
      push_eop     <= 1'b0;
      push_err     <= 1'b0;
      overrun      <= 1'b0;
      burst_end_seen <= 1'b0;
      word_eop     <= 1'b0;
      word_err     <= 1'b0;
    end else begin
      if (rx_grant)
        push_pending <= 1'b0;
      if (word_pulse && auto_push) begin
        if (push_pending && !rx_grant)
          overrun <= 1'b1;
        push_pending <= 1'b1;
        // Include a data bit captured on this same cycle.
        push_byte <= rx_next[7:0];
        push_eop  <= done && burst_mode;
        push_err  <= done && (post_bad || par_bad);
      end

      if (start || burst_next) begin
        word_eop <= auto_pull && tx_eop;
        word_err <= auto_pull && tx_err;
      end
      if (start) begin
        active_r  <= 1'b1;
        index     <= 5'd0;
        lead_wait <= lead;
        rx_word   <= 16'd0;
        post_cap  <= 4'd0;
        par_cap   <= 1'b0;
        post_wrong <= 1'b0;
        burst_end_seen <= 1'b0;
      end else if (burst_next) begin
        index     <= pre_n;
        lead_wait <= lead;
        rx_word   <= 16'd0;
      end else if (active_r) begin
        if (levels[burst[4:0]])
          burst_end_seen <= 1'b1;
        rx_word <= rx_next;
        if (post_sample) begin
          post_cap <= {post_cap[2:0], in_bit};
          if (at_parity)
            par_cap <= in_bit;
          else if (in_bit != post_val)
            post_wrong <= 1'b1;
        end
        if (shift_evt) begin
          if (lead_wait)
            lead_wait <= 1'b0;
          else if (!at_last)
            index <= index + 5'd1;
        end
        if (done || abort)
          active_r <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
