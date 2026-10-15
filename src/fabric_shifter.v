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
//
// A frame starts when the start line is high, or (start line 0 with auto
// pull) whenever the TX FIFO grants a byte. A new frame may start in the
// same cycle the previous one ends, so streams are gapless. `word` pulses at
// every frame end; `stop` pulses when the shifter actually goes idle.
module fabric_shifter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [63:0] lines,
    output wire        tx_request,
    input  wire        tx_grant,
    input  wire [7:0]  tx_data,
    output wire        rx_request,
    input  wire        rx_grant,
    output wire [7:0]  rx_byte,
    output wire        out,
    output wire        active,
    output wire        word_pulse,
    output wire        stop_pulse,
    output wire [15:0] rx_data,
    output wire [15:0] status
);
  reg [15:0] tx_word;
  reg [15:0] frame;
  reg [11:0] step;
  reg [12:0] io;
  reg [15:0] rx_word;
  reg [3:0]  post_cap;
  reg [4:0]  index;
  reg        active_r;
  reg        lead_wait;
  reg        push_pending;
  reg [7:0]  push_byte;
  reg        overrun;
  reg        out_r;

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

  // Frame boundaries depend only on the frame register, so they are
  // registered alongside it (computed from the value being written) instead
  // of passing through an adder chain every cycle.
  wire        frame_we   = cfg_we && cfg_addr == 2'd1;
  wire [3:0]  len_m1_next = frame_we ? cfg_data[3:0] : frame[3:0];
  wire [1:0]  pre_next    = frame_we ? cfg_data[5:4] : frame[5:4];
  wire [1:0]  post_next   = frame_we ? cfg_data[8:7] : frame[8:7];
  wire [1:0]  parity_next = frame_we ? cfg_data[11:10] : frame[11:10];
  wire        idle_next   = frame_we ? cfg_data[15] : frame[15];
  wire [4:0]  len_next   = {1'b0, len_m1_next} + 5'd1;
  wire [4:0]  data_end_next = {3'b0, pre_next} + len_next;
  wire [4:0]  par_end_next  = data_end_next + {4'b0, parity_next != 2'd0};
  reg  [4:0]  data_end, par_end, last_index;
  reg  [15:0] len_mask;
  always @(posedge clk) begin
    if (!rst_n) begin
      data_end   <= 5'd1;
      par_end    <= 5'd1;
      last_index <= 5'd0;
      len_mask   <= 16'd1;
    end else begin
      data_end   <= data_end_next;
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
        frame_bit_at = (^(w & len_mask)) ^ odd_parity;
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
  wire at_last = index == last_index;
  wire done = enable && at_last &&
      (end_on_sample ? sample_now : (shift_evt && !lead_wait));
  wire trigger = start_sel != 6'd0 ? lines[start_sel] : auto_pull;
  wire start = enable && (!active_r || done) && trigger &&
               (!auto_pull || tx_grant);
  wire [31:0] levels = lines[63:32];
  wire in_bit = levels[io[10:6]];
  wire [15:0] data_bit_mask = 16'd1 << data_pos;
  wire [15:0] rx_next = (sample_now && in_data) ?
      ((rx_word & ~data_bit_mask) | (in_bit ? data_bit_mask : 16'd0)) :
      rx_word;

  assign tx_request = enable && (!active_r || done) && trigger && auto_pull;
  assign rx_request = push_pending;
  assign rx_byte    = push_byte;
  assign out        = out_r;
  assign active     = active_r;
  assign word_pulse = done;
  assign stop_pulse = done && !start;
  assign rx_data    = rx_word;
  assign status = {active_r, overrun, push_pending, 9'b0, post_cap};

  always @(posedge clk) begin
    if (!rst_n) begin
      frame <= 16'd0;
      step  <= 12'd0;
      io    <= 13'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        2'd1: frame <= cfg_data;
        2'd2: step  <= cfg_data[11:0];
        2'd3: io    <= cfg_data[12:0];
        default: begin end
      endcase
    end
  end

  // The output is a register so downstream glue and tiles start their
  // paths at a flop. Each candidate (new frame, advance, hold) is
  // precomputed from registers; the shift line only selects among them.
  wire [15:0] start_word = auto_pull ? {8'd0, tx_data} :
      (cfg_we && cfg_addr == 2'd0 && !active_r) ? cfg_data : tx_word;
  wire advance = shift_evt && !lead_wait && !at_last;
  wire bit_start = frame_bit_at(5'd0, start_word);
  wire bit_next  = frame_bit_at(index + 5'd1, tx_word);
  wire bit_hold  = frame_bit_at(index, tx_word);
  always @(posedge clk) begin
    if (!rst_n)
      out_r <= 1'b0;
    else if (start)
      out_r <= bit_start;
    else if (!active_r || done || !enable)
      out_r <= idle_next;
    else
      out_r <= advance ? bit_next : bit_hold;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      tx_word <= 16'd0;
    end else if (start && auto_pull) begin
      tx_word <= {8'd0, tx_data};
    end else if (cfg_we && cfg_addr == 2'd0 && !active_r) begin
      tx_word <= cfg_data;
    end
  end

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      rx_word      <= 16'd0;
      post_cap     <= 4'd0;
      index        <= 5'd0;
      active_r     <= 1'b0;
      lead_wait    <= 1'b0;
      push_pending <= 1'b0;
      push_byte    <= 8'd0;
      overrun      <= 1'b0;
    end else begin
      if (rx_grant)
        push_pending <= 1'b0;
      if (done && auto_push) begin
        if (push_pending && !rx_grant)
          overrun <= 1'b1;
        push_pending <= 1'b1;
        // Include a data bit captured on this same cycle.
        push_byte <= rx_next[7:0];
      end

      if (start) begin
        active_r  <= 1'b1;
        index     <= 5'd0;
        lead_wait <= lead;
        rx_word   <= 16'd0;
        post_cap  <= 4'd0;
      end else if (active_r) begin
        rx_word <= rx_next;
        if (sample_now && !in_pre && !in_data)
          post_cap <= {post_cap[2:0], in_bit};
        if (shift_evt) begin
          if (lead_wait)
            lead_wait <= 1'b0;
          else if (!at_last)
            index <= index + 5'd1;
        end
        if (done)
          active_r <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
