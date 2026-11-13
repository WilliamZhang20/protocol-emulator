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
//   5 coder  [2:0] stuff run N (0: no stuffing)  [3] runs of ones (else
//            of equal bits)  [4] NRZI  [5] code the received bits (else
//            the transmitted ones)  [6] arm at the first 0
//            [7] invert tail bits  [8] word line pulses every frame bit
//            [14:9] tail length  [15] Manchester (transmit)
//   6 coder  [4:0] stuffing gate level (signal space 32-63)  [5] gated
//            [12:6] frame bits not given to the CRC link
//
// Bit coder (registers 5 and 6; all zero: off). It codes the bit stream
// between the frame and the pin, so the stuffing, NRZI and CRC-sequencing
// glue of USB, CAN and HDLC needs no logic cells or counters:
// - Stuffing. After N equal bits in a row (or N ones), a transmitter
//   sends one complemented bit without advancing the frame; a receiver
//   drops the sample after them, and flags the frame err (status bit 4) if
//   that sample was not the complement. A stuff position restarts the run
//   either way. Runs carry across words, bursts
//   and back-to-back frames; they restart when the tile starts from idle.
//   Stuffing waits for the first 0 if [6] is set (CAN's SOF ends an idle
//   bus) and acts only while the gate level is high if [5] of register 6.
// - NRZI. A transmitted 0 toggles the line and a 1 keeps it; the idle
//   level is the line's starting state. A received bit is 1 when the line
//   kept its level since the previous sample (the first compares with the
//   idle level).
// - Tail. After the frame's last bit (and after the last word of a burst)
//   the transmitter sends `tail length` bits from the CRC tile, stuffed
//   like the rest, then ends. A stuff bit due after the last tail bit is
//   still sent.
// - CRC link. The tile gives the CRC tile every frame bit it codes (sent or
//   sampled, never a stuff or tail bit), from the arming 0 on and after
//   the first `register 6 [12:6]` such bits, and steps it once per tail
//   bit, over a direct registered link (the CRC tile selects it).
// - Manchester (transmit, not with NRZI). The shift line ticks every half
//   bit: each bit goes out as its complement, then (at the half-bit tick)
//   as itself, so a 1 is low-high (IEEE 802.3) and every bit has a mid-bit
//   transition. Only the second tick of a bit advances the frame, so
//   stuffing, the tail and the CRC link work per bit as above.
// - Bit strobe. With [8] the word line pulses for every frame bit instead
//   of every word (an RX bit counter for CAN); FIFO pushes stay per word.
// A receiving coder needs the shift and sample lines to be the same.
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
    input  wire        crc_in,      // CRC tile's output bit (tail source)
    output wire [7:0]  rx_byte,
    output wire        rx_eop,
    output wire        rx_err,
    output wire        out,
    output wire        active,
    output wire        word_pulse,
    output wire        stop_pulse,
    output wire [15:0] rx_data,
    output wire [15:0] status,
    output wire        crc_absorb,  // CRC link, registered: absorb crc_bit
    output wire        crc_bit,
    output wire        crc_emit     //   ... or shift out one bit
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
  wire [15:0] coder;
  wire [12:0] coder2;
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
  wire [2:0] stuff_n    = coder[2:0];
  wire       ones_run   = coder[3];
  wire       coder_rx   = coder[5];
  wire       nrzi_tx    = coder[4] && !coder_rx;
  wire       nrzi_rx    = coder[4] && coder_rx;
  wire       sof_arm    = coder[6];
  wire       tail_inv   = coder[7];
  wire       bit_strobe = coder[8];
  wire [5:0] tail_n     = coder[14:9];
  wire       manch      = coder[15] && !coder[5];
  wire [6:0] skip_n     = coder2[12:6];

  // Coder state.
  reg [2:0] run_len;     // equal bits (or ones) in a row, saturating
  reg       cur_bit;     // last coded bit, before NRZI
  reg       armed;       // stuffing and CRC link active
  reg [6:0] skip_left;   // frame bits still kept from the CRC link
  reg       mid;         // Manchester: the bit's second half is on the line
  reg       stuffing;    // TX: the current bit is a stuff bit
  reg       tailing;     // TX: the frame is sending its tail
  reg [5:0] tail_left;   // tail bits after the current one
  reg       prev_in;     // RX NRZI: line level at the previous sample
  reg       stuff_err;   // RX: a stuff bit was not the complement
  reg       crc_absorb_r, crc_bit_r, crc_emit_r;

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

  wire [31:0] levels = lines[63:32];
  wire shift_line = active_r && lines[step[5:0]];
  // Manchester: the first half-bit tick of a bit only flips the line.
  wire half_tick  = manch && shift_line && !lead_wait && !mid;
  wire shift_raw  = shift_line && !half_tick;
  wire sample_raw = active_r && lines[step[11:6]] && !lead_wait;
  // A stuff bit is due once the run is long enough; a transmitter sends
  // it at this boundary instead of advancing, a receiver drops this
  // sample. Neither moves the frame, so they mask the shift and sample.
  wire stuff_due = stuff_n != 3'd0 && run_len >= stuff_n && armed &&
                   (!coder2[5] || levels[coder2[4:0]]);
  wire stuff_tx = !coder_rx && shift_raw && !lead_wait && stuff_due;
  wire stuff_rx = coder_rx && sample_raw && stuff_due;
  wire shift_evt  = shift_raw && !stuff_tx && !stuff_rx;
  wire sample_now = sample_raw && !stuff_rx;
  wire end_evt = end_on_sample ? sample_now : (shift_evt && !lead_wait);
  // `>=` rather than `==`: if the framing changes under a frame in progress
  // (a context switch), the frame still ends at its next end event.
  wire at_last = index >= last_index;
  // A burst continues past this word's last data bit unless the end line
  // has been seen; with auto pull it also needs the next byte.
  wire burst_want = run && burst_mode && !tailing && index == data_last && end_evt &&
                    !(burst_end_seen || levels[burst[4:0]] || (burst[6] && word_eop));
  wire burst_next = burst_want && (!auto_pull || tx_grant);
  wire frame_end_raw = run && at_last && end_evt;
  // A frame with a tail ends only after its tail bits.
  wire tail_pending = !coder_rx && tail_n != 6'd0 && (!tailing || tail_left != 6'd0);
  wire frame_end = frame_end_raw && !tail_pending;
  wire tail_step = frame_end_raw && tail_pending && !burst_next;
  wire done = frame_end && !burst_next;
  wire trigger = start_sel != 6'd0 ? lines[start_sel] : auto_pull;
  wire start = run && (!active_r || done) && trigger &&
               (!auto_pull || tx_grant);
  wire in_line = levels[io[10:6]];
  // The received bit: NRZI-decoded (1 when the line kept its level) or as is.
  wire in_bit = nrzi_rx ? (in_line == prev_in) : in_line;
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

  assign stop_pulse = done && !start;
  assign rx_data    = rx_word;
  assign status = {active_r, overrun, push_pending, 8'b0, stuff_err, post_cap};
  assign crc_absorb = crc_absorb_r;
  assign crc_bit    = crc_bit_r;
  assign crc_emit   = crc_emit_r;

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
  config_bank #(.WIDTH(16)) coder_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 3'd5), .write_bank(cfg_bank), .data(cfg_data),
      .ctx_next(ctx_next), .value(coder), .next());
  config_bank #(.WIDTH(13)) coder2_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 3'd6), .write_bank(cfg_bank), .data(cfg_data[12:0]),
      .ctx_next(ctx_next), .value(coder2), .next());

  // The output is a register so downstream logic cells and tiles start their
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
  wire bit_tail  = crc_in ^ tail_inv;
  // NRZI: a 0 toggles the line, a 1 keeps it. Manchester: the first half
  // of a bit is its complement.
  function automatic line_for(input b);
    line_for = nrzi_tx ? (out_r ^ !b) : (b ^ manch);
  endfunction
  always @(posedge clk) begin
    if (!rst_n)
      out_r <= 1'b0;
    else if (start)
      out_r <= line_for(bit_start);
    else if (burst_next)
      out_r <= line_for(bit_burst);
    else if (!active_r || done || !run)
      out_r <= idle_next;
    else if (half_tick)
      out_r <= !out_r;
    else if (stuff_tx)
      out_r <= line_for(!cur_bit);
    else if (tail_step)
      out_r <= line_for(bit_tail);
    else if (advance)
      out_r <= line_for(bit_next);
    else if (!nrzi_tx && !manch && !stuffing && !tailing)
      out_r <= bit_hold;
  end

  // ---------------------------------------------------------- bit coder
  // One coded bit per event: a transmitted bit (new frame, next burst word,
  // advance, stuff or tail bit) or a received sample (stuff or not).
  wire fresh = start && !active_r;       // starting from idle: runs restart
  wire present_data = start || burst_next || advance;
  wire tx_evt = present_data || stuff_tx || tail_step;
  wire coded_evt = coder_rx ? sample_raw : tx_evt;
  wire coded_bit = coder_rx  ? in_bit :
                   start      ? bit_start :
                   burst_next ? bit_burst :
                   stuff_tx   ? !cur_bit :
                   tail_step  ? bit_tail : bit_next;
  wire coded_stuff = stuff_tx || stuff_rx;
  // A frame bit: neither a stuff bit nor a tail bit.
  wire bit_taken = coder_rx ? sample_now : present_data;
  // Preserve the stuff/tail priority when a word boundary and a new start
  // share a clock. The CRC link sees only an accepted frame bit.
  wire crc_frame_bit = coder_rx ? sample_now :
                       (present_data && !stuff_tx && !tail_step);
  wire word_end = done || burst_next;
  assign word_pulse = bit_strobe ? bit_taken : word_end;
  wire [2:0] run_b   = fresh ? 3'd0 : run_len;
  wire       armed_b = fresh ? !sof_arm : armed;
  wire [6:0] skip_b  = fresh ? skip_n : skip_left;
  wire [2:0] run_inc = run_b == 3'd7 ? 3'd7 : run_b + 3'd1;
  // A stuff position always restarts the run, as a correct stuff bit
  // would (a wrong one is flagged, and the stream stays in step).
  wire [2:0] run_new = (ones_run && (coded_stuff || !coded_bit)) ? 3'd0 :
                       ones_run ? run_inc :
                       (!coded_stuff && run_b != 3'd0 && coded_bit == cur_bit) ? run_inc : 3'd1;
  wire       armed_new = armed_b || !coded_bit;
  wire       stuff_bad = stuff_rx && (ones_run ? in_bit : in_bit == cur_bit);

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      run_len      <= 3'd0;
      cur_bit      <= 1'b0;
      armed        <= 1'b0;
      skip_left    <= 7'd0;
      mid          <= 1'b0;
      stuffing     <= 1'b0;
      tailing      <= 1'b0;
      tail_left    <= 6'd0;
      prev_in      <= 1'b0;
      stuff_err    <= 1'b0;
      crc_absorb_r <= 1'b0;
      crc_bit_r    <= 1'b0;
      crc_emit_r   <= 1'b0;
    end else begin
      crc_absorb_r <= 1'b0;
      crc_emit_r   <= 1'b0;
      if (fresh) begin
        run_len   <= 3'd0;
        armed     <= !sof_arm;
        skip_left <= skip_n;
        stuff_err <= 1'b0;
        prev_in   <= idle_next;
      end
      if (coded_evt && run) begin
        run_len <= run_new;
        cur_bit <= coded_bit;
        armed   <= armed_new;
        if (stuff_bad)
          stuff_err <= 1'b1;
      end
      // crc_frame_bit implies coded_evt. Keeping this update separate from
      // the coder-state update avoids the tx/stuff/tail event OR on its path.
      if (crc_frame_bit && run && armed_new) begin
        if (skip_b != 7'd0) begin
          skip_left <= skip_b - 7'd1;
        end else begin
          crc_absorb_r <= 1'b1;
          crc_bit_r    <= coded_bit;
        end
      end
      if (sample_raw && nrzi_rx)
        prev_in <= in_line;
      if (half_tick)
        mid <= 1'b1;
      else if (tx_evt || !active_r || done || !run)
        mid <= 1'b0;
      // Transmit phase: a stuff bit or the tail is on the line.
      if (tx_evt || !active_r || done || !run)
        stuffing <= stuff_tx;
      if (start || !active_r || done || !run)
        tailing <= 1'b0;
      else if (tail_step) begin
        tailing   <= 1'b1;
        tail_left <= (tailing ? tail_left : tail_n) - 6'd1;
        crc_emit_r <= 1'b1;
      end
    end
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
      if (word_end && auto_push) begin
        if (push_pending && !rx_grant)
          overrun <= 1'b1;
        push_pending <= 1'b1;
        // Include a data bit captured on this same cycle.
        push_byte <= rx_next[7:0];
        push_eop  <= done && burst_mode;
        push_err  <= done && (post_bad || par_bad || stuff_err || stuff_bad);
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
