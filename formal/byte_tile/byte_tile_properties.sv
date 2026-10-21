`default_nettype none

// Byte tiles, checked end to end against what a protocol needs from them
// rather than against their own state machines:
//  * ESCAPE -> UNESCAPE round trip: for any valid escape map (symbolic
//    codes with {c0, c1} = {F, E}, F != E, m0 != m1, and m0, m1 not F or
//    E) and any packet stream, every byte and every eop tag arrives
//    exactly as it was sent, untagged err, and nothing is invented;
//  * CHECK generate -> verify: a packet is tagged err exactly when one of
//    its bytes was corrupted on the link (any nonzero xor, symbolic place),
//    or, in the other mode, when the sender tagged its last byte err to
//    inject an error; add and xor checksums, any initial value;
//  * every tile output: a byte waiting to be taken stays unchanged.
// Sources obey the handshake rule (hold a byte until it is taken); sinks
// accept arbitrarily. Single-clock harness: one solver step is one cycle.
// CHAIN selects which source may send (1: round trip, 2: checksums), so
// each check explores only its own inputs; the wrappers at the end are the
// formal tops.
module byte_tile_properties #(parameter CHAIN = 1) (input wire clk);
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  reg [2:0] init = 3'd0;            // config writes, then the tiles run
  wire live = init == 3'd4;

  // ------------------------------------------------- symbolic configuration
  (* anyconst *) reg [7:0] delim, esc, m0, m1;
  (* anyconst *) reg       swap, prepend;
  wire [7:0] c0 = swap ? esc : delim;
  wire [7:0] c1 = swap ? delim : esc;
  always @(*) assume(delim != esc && m0 != m1 && m0 != delim && m0 != esc &&
                     m1 != delim && m1 != esc);
  (* anyconst *) reg       use_xor, inject_mode;
  (* anyconst *) reg [7:0] init_value, flip;
  (* anyconst *) reg [2:0] flip_at;
  always @(*) assume(flip != 8'd0);

  // Written one register per cycle while the tiles are disabled.
  wire [1:0]  cfg_addr = init[1:0];
  wire        cfg_we = rst_n && !live;
  wire [15:0] map_cfg = cfg_addr == 2'd1 ? {c1, c0} :
                        cfg_addr == 2'd2 ? {m1, m0} : {delim, esc};
  wire [15:0] sum_cfg = cfg_addr == 2'd1 ? {8'd0, init_value} : 16'd0;
  wire [15:0] cfg_esc   = cfg_addr == 2'd0 ? {9'd0, prepend, 1'b1, 3'd1} : map_cfg;
  wire [15:0] cfg_unesc = cfg_addr == 2'd0 ? 16'd2 : map_cfg;
  wire [15:0] cfg_gen   = cfg_addr == 2'd0 ? {10'd0, use_xor, 2'd0, 3'd4} : sum_cfg;
  wire [15:0] cfg_ver   = cfg_addr == 2'd0 ? {9'd0, 1'b1, use_xor, 2'd0, 3'd4} : sum_cfg;

  (* anyseq *) reg [63:0] lines_any;
  wire [63:0] lines = {lines_any[63:2], 1'b1, 1'b0};

  // ------------------------------------------------------------ sources
  (* anyseq *) reg       a_valid_any, a_eop_any, b_valid_any, b_eop_any, b_err_any;
  (* anyseq *) reg [7:0] a_data_any, b_data_any;
  (* anyseq *) reg       a_ready_out, b_ready_out;
  reg a_hold = 1'b0, b_hold = 1'b0;
  reg [7:0] a_data_h = 8'd0, b_data_h = 8'd0;
  reg a_eop_h = 1'b0, b_eop_h = 1'b0, b_err_h = 1'b0;
  wire       a_valid = a_hold || a_valid_any;
  wire [7:0] a_data  = a_hold ? a_data_h : a_data_any;
  wire       a_eop   = a_hold ? a_eop_h : a_eop_any;
  wire       b_valid = b_hold || b_valid_any;
  wire [7:0] b_data  = b_hold ? b_data_h : b_data_any;
  wire       b_eop   = b_hold ? b_eop_h : b_eop_any;
  wire       b_err   = (b_hold ? b_err_h : b_err_any) && inject_mode && b_eop;

  // ------------------------------------------------------- the two chains
  wire a_in_ready, a_mid_valid, a_mid_eop, a_mid_err, a_mid_ready;
  wire [7:0] a_mid_data, a_out_data;
  wire a_out_valid, a_out_eop, a_out_err, unused_a0, unused_a1;
  byte_tile escape (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_esc), .lines(lines),
      .in_valid(a_valid), .in_data(a_data), .in_eop(a_eop), .in_err(1'b0),
      .in_ready(a_in_ready),
      .out_valid(a_mid_valid), .out_data(a_mid_data), .out_eop(a_mid_eop),
      .out_err(a_mid_err), .out_ready(a_mid_ready), .event_pulse(unused_a0));
  byte_tile unescape (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_unesc), .lines(lines),
      .in_valid(a_mid_valid), .in_data(a_mid_data), .in_eop(a_mid_eop),
      .in_err(a_mid_err), .in_ready(a_mid_ready),
      .out_valid(a_out_valid), .out_data(a_out_data), .out_eop(a_out_eop),
      .out_err(a_out_err), .out_ready(a_ready_out), .event_pulse(unused_a1));

  wire b_in_ready, b_mid_valid, b_mid_eop, b_mid_err, b_mid_ready;
  wire [7:0] b_mid_data, b_out_data;
  wire b_out_valid, b_out_eop, b_out_err, unused_b0, unused_b1;
  reg [2:0] link_count = 3'd0;      // bytes moved over the gen -> verify link
  wire b_link = live && b_mid_valid && b_mid_ready;
  reg flipped = 1'b0;               // one corrupted byte per run at most
  wire b_corrupt = !inject_mode && b_link && link_count == flip_at && !flipped;
  byte_tile generate_sum (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_gen), .lines(lines),
      .in_valid(b_valid), .in_data(b_data), .in_eop(b_eop), .in_err(b_err),
      .in_ready(b_in_ready),
      .out_valid(b_mid_valid), .out_data(b_mid_data), .out_eop(b_mid_eop),
      .out_err(b_mid_err), .out_ready(b_mid_ready), .event_pulse(unused_b0));
  byte_tile verify_sum (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_ver), .lines(lines),
      .in_valid(b_mid_valid),
      .in_data(b_corrupt ? b_mid_data ^ flip : b_mid_data),
      .in_eop(b_mid_eop), .in_err(b_mid_err), .in_ready(b_mid_ready),
      .out_valid(b_out_valid), .out_data(b_out_data), .out_eop(b_out_eop),
      .out_err(b_out_err), .out_ready(b_ready_out), .event_pulse(unused_b1));

  // ---------------------------------------------------------- scoreboards
  (* anyconst *) reg [2:0] watch;
  reg [2:0] a_sent = 3'd0, a_got = 3'd0;
  reg [7:0] a_watch_data = 8'd0;
  reg       a_watch_eop = 1'b0, a_watched = 1'b0;
  wire a_send = live && a_valid && a_in_ready;
  wire a_take = live && a_out_valid && a_ready_out;

  reg [1:0] b_sent_pkts = 2'd0, b_link_pkts = 2'd0, b_got_pkts = 2'd0;
  reg [3:0] b_bad = 4'd0;           // packet k must arrive tagged err
  wire b_send = live && b_valid && b_in_ready;
  wire b_take = live && b_out_valid && b_ready_out;

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && !live)
      init <= init + 3'd1;
    // Sources hold an offered byte until it is taken.
    a_hold <= a_valid && !a_in_ready && live;
    if (a_valid && !a_hold) begin a_data_h <= a_data_any; a_eop_h <= a_eop_any; end
    b_hold <= b_valid && !b_in_ready && live;
    if (b_valid && !b_hold) begin
      b_data_h <= b_data_any; b_eop_h <= b_eop_any; b_err_h <= b_err_any;
    end
    if (a_send) begin
      a_sent <= a_sent + 3'd1;
      if (a_sent == watch) begin
        a_watch_data <= a_data; a_watch_eop <= a_eop; a_watched <= 1'b1;
      end
    end
    if (a_take)
      a_got <= a_got + 3'd1;
    if (b_send && b_eop) begin
      b_sent_pkts <= b_sent_pkts + 2'd1;
      if (b_err) b_bad[b_sent_pkts] <= 1'b1;
    end
    if (b_link) begin
      link_count <= link_count + 3'd1;
      if (b_mid_eop) b_link_pkts <= b_link_pkts + 2'd1;
      if (b_corrupt) begin b_bad[b_link_pkts] <= 1'b1; flipped <= 1'b1; end
    end
    if (b_take && b_out_eop)
      b_got_pkts <= b_got_pkts + 2'd1;
  end

  // The sources stay quiet until configured, and send few enough bytes
  // that the counters cannot wrap.
  always @(*) begin
    if (!live) assume(!a_valid_any && !b_valid_any);
    if (CHAIN != 1) assume(!a_valid_any);
    if (CHAIN != 2) assume(!b_valid_any);
    if (a_sent == 3'd7) assume(!a_valid_any);
    if (b_sent_pkts == 2'd3 || link_count == 3'd7) assume(!b_valid_any);
  end

  // ---------------------------------------------------------- assertions
  reg past_valid = 1'b0;
  reg [3:0]  past_wait;
  reg [7:0]  past_data [0:3];
  reg [3:0]  past_tags_eop, past_tags_err;
  always @(posedge clk) begin
    past_valid <= rst_n;
    past_wait <= {a_out_valid && !a_ready_out, a_mid_valid && !a_mid_ready,
                  b_out_valid && !b_ready_out, b_mid_valid && !b_mid_ready};
    past_data[3] <= a_out_data; past_data[2] <= a_mid_data;
    past_data[1] <= b_out_data; past_data[0] <= b_mid_data;
    past_tags_eop <= {a_out_eop, a_mid_eop, b_out_eop, b_mid_eop};
    past_tags_err <= {a_out_err, a_mid_err, b_out_err, b_mid_err};
  end

  always @(*) begin
    if (rst_n && past_valid) begin
      // Round trip: the watched byte arrives intact, in order, untagged err.
      if (a_take) assert(a_got < a_sent);
      if (a_take && a_got == watch && a_watched)
        assert(a_out_data == a_watch_data && a_out_eop == a_watch_eop);
      if (a_take) assert(!a_out_err);
      // Checksums: err exactly on corrupted or injected packets.
      if (b_take && b_out_eop) assert(b_out_err == b_bad[b_got_pkts]);
      // Handshake: a waiting byte does not change.
      if (past_wait[3] && live) assert(a_out_valid && a_out_data == past_data[3] &&
                                       a_out_eop == past_tags_eop[3] &&
                                       a_out_err == past_tags_err[3]);
      if (past_wait[2] && live) assert(a_mid_valid && a_mid_data == past_data[2] &&
                                       a_mid_eop == past_tags_eop[2]);
      if (past_wait[1] && live) assert(b_out_valid && b_out_data == past_data[1] &&
                                       b_out_err == past_tags_err[1]);
      if (past_wait[0] && live) assert(b_mid_valid && b_mid_data == past_data[0] &&
                                       b_mid_eop == past_tags_eop[0]);
    end
  end

  always @(*) begin
    if (rst_n && live) begin
      // An escaped byte that ends a packet comes back as it was sent.
      if (CHAIN == 1)
        cover(a_take && a_out_eop && (a_out_data == c0 || a_out_data == c1));
      if (CHAIN == 2) begin
        cover(b_take && b_out_eop && b_out_err && !inject_mode);   // caught
        cover(b_take && b_out_eop && b_out_err && inject_mode);    // injected
        cover(b_take && b_out_eop && !b_out_err && b_got_pkts == 2'd1);
      end
    end
  end
endmodule

module byte_tile_roundtrip (input wire clk);
  byte_tile_properties #(.CHAIN(1)) check (.clk(clk));
endmodule

module byte_tile_checksum (input wire clk);
  byte_tile_properties #(.CHAIN(2)) check (.clk(clk));
endmodule

`default_nettype wire
