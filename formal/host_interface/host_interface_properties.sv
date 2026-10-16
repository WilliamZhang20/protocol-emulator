`default_nettype none

// Host link decoder against the pin-level contract, with ui_in driven by an
// unconstrained (asynchronous, glitching) host:
//  * soundness: every strobe and state change traces back to one command
//    byte that was on the pins at two consecutive clock edges, and a second
//    strobe needs 8'h00 on the pins at two consecutive edges in between;
//  * completeness: a stable 8'h00 followed by a stable command always acts;
//  * data paths: payload nibbles, address post-increment, SRAM readback
//    capture, FIFO channel select, and engine stop on halt.
module host_interface_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg [7:0] host_in;
  (* anyseq *) reg [7:0] program_read_data;
  (* anyseq *) reg       tx_full;
  (* anyseq *) reg [2:0] tx_level;
  (* anyseq *) reg [9:0] rx_pop_data;     // {err, eop, byte}
  (* anyseq *) reg       rx_empty;
  (* anyseq *) reg [2:0] rx_level;
  (* anyseq *) reg       engine_halted;

  wire [7:0] host_out, program_write_data, program_write_mask;
  wire [9:0] tx_push_data;
  wire [9:0] program_address;
  wire engine_enable, program_enable, program_write, program_read;
  wire channel, tx_push, rx_pop;

  host_interface dut (
      .clk(clk), .rst_n(rst_n), .host_in(host_in), .host_out(host_out),
      .engine_enable(engine_enable), .program_enable(program_enable),
      .program_write(program_write), .program_read(program_read),
      .program_address(program_address),
      .program_write_data(program_write_data),
      .program_write_mask(program_write_mask),
      .program_read_data(program_read_data), .channel(channel),
      .tx_push(tx_push), .tx_push_data(tx_push_data), .tx_full(tx_full),
      .tx_level(tx_level), .rx_pop(rx_pop), .rx_pop_data(rx_pop_data),
      .rx_empty(rx_empty), .rx_level(rx_level), .engine_halted(engine_halted)
  );

  // Pin history: p[k] is ui_in at the k-th most recent clock edge. A
  // command decided from edges (e0, e1) acts on the register edge e3, so in
  // the cycle after e3 its two samples are p[3] (e1) and p[4] (e0).
  reg [7:0] p1 = 0, p2 = 0, p3 = 0, p4 = 0, p5 = 0, p6 = 0;
  reg past_valid = 1'b0, past_enable = 1'b0, past_tx_full = 1'b0;
  reg past_rx_empty = 1'b0, past_write = 1'b0, past_read = 1'b0;
  reg past_read2 = 1'b0, past_halted = 1'b0;
  reg [9:0] past_address = 10'd0;
  reg [7:0] past_read_data = 8'd0;
  reg [9:0] past_rx_entry = 10'd0;
  reg past_channel = 1'b0;
  reg rearmed = 1'b1;           // 8'h00 seen stable since the last strobe

  wire stable_cmd = p3 == p4 && p3 != 8'h00;
  wire [3:0] cmd = p3[7:4];
  wire zero_gap = p5 == 8'h00 && p6 == 8'h00;
  wire strobe = program_write || program_read || tx_push || rx_pop;
  wire rearmed_now = rearmed || zero_gap;
  // At least five edges since reset, so the history is all post-reset.
  reg [2:0] age = 3'd0;
  wire settled = age == 3'd6 && past_valid;

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    p1 <= host_in; p2 <= p1; p3 <= p2; p4 <= p3; p5 <= p4; p6 <= p5;
    past_valid <= rst_n;
    past_enable <= engine_enable;
    past_tx_full <= tx_full;
    past_rx_empty <= rx_empty;
    past_write <= program_write;
    past_read <= program_read;
    past_read2 <= past_read;
    past_halted <= engine_halted;
    past_address <= program_address;
    past_read_data <= program_read_data;
    past_rx_entry <= rx_pop_data;
    past_channel <= channel;
    if (!rst_n) begin
      age <= 3'd0;
      rearmed <= 1'b1;
    end else begin
      if (age != 3'd6) age <= age + 3'd1;
      rearmed <= strobe ? 1'b0 : rearmed_now;
    end
  end

  always @(*) begin
    if (rst_n && settled) begin
      // Soundness: the strobe's command was stable on the pins.
      if (program_write) assert(stable_cmd && cmd == 4'h5 && !past_enable);
      if (program_read)  assert(stable_cmd && cmd == 4'hb && !past_enable);
      if (tx_push)       assert(stable_cmd && (cmd == 4'h7 || cmd == 4'hf) && !past_tx_full);
      // F tags the pushed byte as a packet's last; host bytes never carry err.
      if (tx_push)       assert(tx_push_data[8] == (cmd == 4'hf) && !tx_push_data[9]);
      if (rx_pop)        assert(stable_cmd && cmd == 4'h9 && !past_rx_empty);
      if (strobe)        assert(rearmed_now);
      assert(!(program_write && program_read) && !(tx_push && rx_pop));
      if (program_write || tx_push) assert(program_write_data[7:4] == p3[3:0]);
      if (program_write) assert(!engine_enable);
      // Completeness: a clean gap then a stable command always acts.
      if (zero_gap && stable_cmd) begin
        if (cmd == 4'h5) assert(program_write == !past_enable);
        if (cmd == 4'hb) assert(program_read == !past_enable);
        if (cmd == 4'h7 || cmd == 4'hf) assert(tx_push == !past_tx_full);
        // Status reports the next RX byte's tags in its low bits.
        if (cmd == 4'ha) assert(host_out[1:0] == {past_rx_entry[8], past_rx_entry[9]});
        if (cmd == 4'h9) assert(rx_pop == !past_rx_empty);
        if (cmd == 4'he) assert(channel == p3[0]);
      end
      // The address moves only by a stable address command or a write.
      if (program_address != past_address)
        assert(past_write || (stable_cmd && (cmd == 4'h1 || cmd == 4'h2 || cmd == 4'h3)));
      if (past_write) assert(program_address == past_address + 10'd1);
      if (channel != past_channel) assert(stable_cmd && cmd == 4'he);
      // SRAM data registered on the read cycle reaches the pins next.
      if (past_read2) assert(host_out == past_read_data);
      // Halt stops the engine (a start decoded in that same cycle re-arms
      // it; the core is still halted, so it stops again a cycle later).
      if (past_halted && !(stable_cmd && cmd == 4'h8 && p3[0])) assert(!engine_enable);
      if (engine_enable != past_enable && !past_halted) assert(stable_cmd && cmd == 4'h8);
      assert(program_enable == (program_write || program_read));
      assert(program_write_mask == 8'hff);
      assert(tx_push_data[7:0] == program_write_data);
    end
  end

  always @(*) begin
    if (rst_n && settled) begin
      cover(program_write && program_address == 10'd3);
      cover(past_read2 && host_out == 8'ha5);
      cover(tx_push && channel);
      cover(tx_push && tx_push_data[8]);
    end
  end
endmodule

`default_nettype wire
