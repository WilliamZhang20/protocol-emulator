`default_nettype none

// Shifter tile against an independently written frame model:
//  * while active, `out` is exactly the frame bit at the model's index
//    (pre / data in either bit order / parity / post, with lead mode);
//  * with the input pin looped back to `out`, a frame whose data bits were
//    all sampled reproduces the transmitted word in rx_data and the RX push;
//  * FIFO handshakes never drop or invent bytes, and overrun is flagged.
module fabric_shifter_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [1:0]  cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [31:0] events_any;
  (* anyseq *) reg [7:0]  pins_any;
  (* anyseq *) reg        tx_ready;
  (* anyseq *) reg [7:0]  tx_data;
  (* anyseq *) reg        rx_ready;
  wire [31:0] events = {events_any[31:2], 1'b1, 1'b0};
  wire tx_request, rx_request, out, start_pulse, done_pulse;
  wire [7:0] rx_byte;
  wire [15:0] rx_data, status;
  wire tx_grant = tx_request && tx_ready;
  wire rx_grant = rx_request && rx_ready;
  wire active = status[15];

  // Loop the selected input pin back to the shifter's own output.
  reg [2:0] in_pin_s = 3'd0;
  wire [7:0] pins = (pins_any & ~(8'd1 << in_pin_s)) | ({7'd0, out} << in_pin_s);

  fabric_shifter dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .events(events), .pins(pins),
      .tx_request(tx_request), .tx_grant(tx_grant), .tx_data(tx_data),
      .rx_request(rx_request), .rx_grant(rx_grant), .rx_byte(rx_byte),
      .out(out), .start_pulse(start_pulse), .done_pulse(done_pulse),
      .rx_data(rx_data), .status(status)
  );

  // Shadow configuration, written only while the tile is idle and not
  // starting (the controller's programming rule).
  reg [15:0] frame_s = 16'd0, ctl_s = 16'd0, data_s = 16'd0;
  reg [4:0]  io_s = 5'd0;
  wire write_frame_ctl_io = cfg_we && cfg_addr != 2'd0;
  always @(*) if (rst_n && write_frame_ctl_io) assume(!active && !start_pulse);

  wire [4:0] len  = {1'b0, frame_s[3:0]} + 5'd1;
  wire [1:0] npre = frame_s[5:4];
  wire [1:0] npost = frame_s[8:7];
  wire has_par = frame_s[11:10] != 2'd0;
  wire lead = frame_s[13];
  wire end_on_sample = frame_s[14];
  wire [4:0] total = {3'd0, npre} + len + {4'd0, has_par} + {3'd0, npost};

  // Frame as a bit vector, built position by position.
  reg [15:0] word;     // word latched at start
  function automatic [31:0] build_frame(input [15:0] w);
    integer i, pos;
    reg par;
    begin
      build_frame = 32'd0;
      par = frame_s[11];
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
  reg [15:0] r_sampled = 16'd0;
  wire shift_evt  = active && events[ctl_s[4:0]];
  wire sample_now = active && events[ctl_s[9:5]] && !r_lead;
  wire [31:0] frame_bits = build_frame(word);
  wire in_data = r_idx >= {3'd0, npre} && r_idx < {3'd0, npre} + len;
  wire [4:0] data_i = r_idx - {3'd0, npre};
  wire [3:0] data_pos = frame_s[12] ? (len[3:0] - 4'd1 - data_i[3:0]) : data_i[3:0];
  wire at_last = r_idx == total - 5'd1;
  wire expect_done = active && at_last &&
      (end_on_sample ? sample_now : (shift_evt && !r_lead));
  wire [15:0] len_mask = 16'hffff >> (5'd16 - len);

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      frame_s <= 16'd0; ctl_s <= 16'd0; data_s <= 16'd0; io_s <= 5'd0;
      in_pin_s <= 3'd0; word <= 16'd0;
      r_idx <= 5'd0; r_lead <= 1'b0; r_sampled <= 16'd0;
    end else begin
      if (cfg_we) begin
        case (cfg_addr)
          2'd0: if (!active && !(start_pulse && io_s[3])) data_s <= cfg_data;
          2'd1: frame_s <= cfg_data;
          2'd2: ctl_s <= cfg_data;
          default: begin io_s <= cfg_data[4:0]; in_pin_s <= cfg_data[2:0]; end
        endcase
      end
      if (start_pulse && io_s[3])
        data_s <= {8'd0, tx_data};   // a pulled byte replaces the data word
      if (start_pulse) begin
        // A data write in the start cycle is the word sent (unless pulling).
        word <= io_s[3] ? {8'd0, tx_data} :
                (cfg_we && cfg_addr == 2'd0) ? cfg_data : data_s;
        r_idx <= 5'd0; r_lead <= lead; r_sampled <= 16'd0;
      end else if (active) begin
        if (sample_now && in_data)
          r_sampled <= r_sampled | (16'd1 << data_pos);
        if (shift_evt) begin
          if (r_lead) r_lead <= 1'b0;
          else if (!at_last) r_idx <= r_idx + 5'd1;
        end
      end
    end
  end

  reg past_valid = 1'b0;
  reg past_check, past_push_check, past_overrun_case, past_rx_hold;
  reg [15:0] past_word;
  always @(posedge clk) begin
    past_valid <= rst_n;
    past_check <= done_pulse && enable &&
        ((r_sampled | (sample_now && in_data ? 16'd1 << data_pos : 16'd0)) & len_mask) == len_mask;
    past_push_check <= done_pulse && enable && io_s[4];
    past_overrun_case <= done_pulse && enable && io_s[4] && rx_request && !rx_grant;
    past_rx_hold <= enable && rx_request && !rx_grant;
    past_word <= word;
  end

  always @(*) begin
    if (rst_n) begin
      if (active && enable) assert(out == frame_bits[r_idx]);
      if (!active) assert(out == frame_s[15]);
      assert(done_pulse == (enable && expect_done));
      if (start_pulse) assert(!active && enable);
      if (tx_request) assert(!active);
      if (active) assert(r_idx < total);
    end
  end

  always @(posedge clk) begin
    if (rst_n && past_valid) begin
      if (past_check) assert((rx_data & len_mask) == (past_word & len_mask));
      if (past_check && past_push_check && len >= 5'd8)
        assert(rx_request && rx_byte == past_word[7:0]);
      if (past_overrun_case && enable) assert(status[14]);
      if (past_rx_hold && enable) assert(rx_request);
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover(done_pulse && has_par && npre == 2'd1 && npost == 2'd1 && len == 5'd8);
      cover(done_pulse && lead && end_on_sample && frame_s[12]);
    end
  end
endmodule

`default_nettype wire
