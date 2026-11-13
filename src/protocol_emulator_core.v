`default_nettype none

// Spatial protocol engine in two layers. Bit-level behavior comes from a
// fabric of statically configured tiles that run every cycle without
// instruction fetch: 4 timers, 2 shifters, 2 counters, 2 CRCs, 8 logic
// cells (LUT4+FF), 8 edge cells and 8 pin cells. Every tile input is a 6-bit select into one
// 64-line signal space. Between each shifter and its FIFO channel, a byte
// layer of stream tiles (two per direction) works on tagged bytes
// {err, eop, data}: escaping, packet delimiting, checksums, filtering. A
// small PX8 controller configures both layers and makes transaction-level
// decisions.
//
// Signal space (lines 2-25 are registered one-cycle pulses; 26-31 are
// spare and read 0; the rest are levels):
//   0 zero   1 one   2-3 controller FIRE 0/1
//   4+2k / 5+2k   timer k rise / fall          (k = 0..3)
//   12+2k / 13+2k shifter k word / stop        (k = 0..1)
//   16+e          edge cell e (a configured pin edge, synchronized)
//   24+k          counter k hit
//   32+p          pin p level (synchronized)
//   40+k timer k out    44+k shifter k out    46+k shifter k active
//   48+k counter k >= threshold    50 CRC 1 out bit   51 CRC 1 matches
//   52 CRC 0 out bit   53 CRC 0 matches check   54-55 controller flags 0/1
//   56+k logic cell k output
//
// Every signal-space line is a register output (logic cells included), so
// no configuration can form a loop and every path is one hop: register,
// line, selector, tile logic, register.
//
// Config map (controller WCF address):
//   0x00-0x0F timer addr[3:2], reg addr[1:0]
//   0x10-0x17 shifter addr[2], reg addr[1:0]
//   0x18-0x1F pin p: [4:0] source level (signal space 32-63),
//             [5] constant: drive [4] instead, [7:6] mode: 0 input,
//             1 push-pull, 2 open-drain, 3 push-pull
//   0x20-0x27 counter addr[2], reg addr[1:0]
//   0x28-0x2F CRC reg addr[2:0]
//   0x30      controller flags [1:0]
//   0x31      [0] arm: tiles and pin outputs stay idle until armed, so a
//             partially written configuration can never act
//   0x32-0x33 shifter k burst register (shifter reg 4)
//   0x34      context select [5:0] line, [6] enable
//   0x35      contexts written [1:0] (reset 01: context 0)
//   0x36-0x37 shifter k bit coder register (shifter reg 5)
//   0x38-0x39 shifter k bit coder gate/skip register (shifter reg 6)
//   0x80-0x87 edge cell e (see fabric_edge)
//   0x88-0x8F CRC 1 reg addr[2:0] (CRC 0 is 0x28-0x2F)
//   0x60-0x7F byte tile t = {channel, rx, stage} addr[4:2], reg addr[1:0];
//             TX: TX FIFO -> stage 0 -> stage 1 -> shifter;
//             RX: shifter -> stage 0 -> stage 1 -> RX FIFO

//   0x40-0x5F logic cell addr[4:2], reg addr[1:0]
//
// Readback map (controller RD address):
//   0 pins   1/3 shifter 0/1 rx data   2/4 shifter 0/1 status
//   5/6 counter 0/1 count   7/8 CRC 0 [15:0]/[31:16]
//   9/10 sticky pulses [15:0]/[31:16]   11/12 CRC 1 [15:0]/[31:16]
//
// Event index 64+t (WEV with opnd[6]) waits for byte tile t's event; these
// are sticky like the pulse lines.
module protocol_emulator_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    output wire [9:0] instruction_address,
    output wire       instruction_read,
    input  wire [7:0] instruction_data,
    // FIFO channel k = {TX FIFO k, RX FIFO k}, k = 0..1. Entries are
    // {err, eop, data} and are packed with channel 1 in the upper half.
    input  wire [19:0] tx_data,
    input  wire [1:0]  tx_empty,
    output wire [1:0]  tx_pop,
    input  wire [1:0]  tx_full,
    output wire [1:0]  tx_push,
    output wire [9:0]  tx_push_data,
    output wire [19:0] rx_data,
    output wire [1:0]  rx_push,
    input  wire [1:0]  rx_full,
    input  wire [7:0] gpio_in,
    output wire [7:0] gpio_out,
    output wire [7:0] gpio_oe,
    output wire       halted
);
  // ---------------------------------------------------------------- pins in
  (* async_reg = "true" *) reg [7:0] pin_meta;
  (* async_reg = "true" *) reg [7:0] pin_sync;
  // Shifter 1 reads an inverted copy of the synchronized pin levels. The
  // inversion restores the same value in the same cycle, while the distinct
  // register encoding keeps synthesis from merging its fanout tree with
  // the general fabric and shifter 0.
  (* async_reg = "true" *) reg [7:0] pin_sync_sh1_n;
  reg [7:0] pin_prev;
  always @(posedge clk) begin
    if (!rst_n) begin
      pin_meta <= 8'd0;
      pin_sync <= 8'd0;
      pin_sync_sh1_n <= 8'hff;
      pin_prev <= 8'd0;
    end else begin
      pin_meta <= gpio_in;
      pin_sync <= pin_meta;
      pin_sync_sh1_n <= ~pin_meta;
      pin_prev <= pin_sync;
    end
  end

  // ------------------------------------------------------------- controller
  // Configuration writes are registered once before they reach the tiles,
  // so a byte read from SRAM (CFG blocks) ends at a flip-flop instead of
  // running on into the tiles' logic. Every write lands one cycle later.
  wire        cpu_cfg_we;
  wire [7:0]  cpu_cfg_addr;
  wire [15:0] cpu_cfg_data;
  reg         cfg_we;
  reg  [7:0]  cfg_addr;
  reg  [15:0] cfg_data;
  always @(posedge clk) begin
    if (!rst_n) begin
      cfg_we   <= 1'b0;
      cfg_addr <= 8'd0;
      cfg_data <= 16'd0;
    end else begin
      cfg_we   <= cpu_cfg_we;
      cfg_addr <= cpu_cfg_addr;
      cfg_data <= cpu_cfg_data;
    end
  end
  wire [3:0]  rd_addr;
  reg  [15:0] rd_data;
  wire        event_consume;
  wire [6:0]  event_index;
  wire        clear_events;
  wire [1:0]  cpu_fire;
  wire        cpu_channel;
  wire        cpu_tx_request;
  wire        cpu_rx_request;
  wire        cpu_tx_push;
  wire [7:0]  cpu_rx_data;
  wire        cpu_push_eop, cpu_push_err;
  wire [9:0]  cpu_entry = {cpu_push_err, cpu_push_eop, cpu_rx_data};

  // ------------------------------------------------------------ signal space
  wire [3:0]  t_out, t_rise, t_fall;
  wire [1:0]  s_out, s_active, s_word, s_stop;
  wire [1:0]  c_ge, c_hit;
  wire [1:0]  crc_out, crc_ok;
  wire [7:0]  logic_q;
  wire [7:0]  edge_pulse;
  reg  [25:2] pulse_reg;
  reg  [1:0]  flags;
  reg         armed;
  reg  [25:2] sticky;
  reg  [7:0]  byte_sticky;
  wire [7:0]  byte_events;
  wire        live = enable && armed;

  wire [63:0] lines = {
      logic_q,                     // 63:56
      flags, crc_ok[0], crc_out[0],   // 55:52
      crc_ok[1], crc_out[1], c_ge,    // 51:48
      s_active, s_out,           // 47:44
      t_out,                     // 43:40
      pin_sync,                  // 39:32
      6'd0, pulse_reg, 1'b1, 1'b0     // 31:0
  };
  wire [25:2] pulse_next = {
      c_hit,                     // 25:24 counter hit
      edge_pulse,                // 23:16 edge cells
      s_stop[1], s_word[1], s_stop[0], s_word[0],
      t_fall[3], t_rise[3], t_fall[2], t_rise[2],
      t_fall[1], t_rise[1], t_fall[0], t_rise[0],
      cpu_fire
  };
  // Index 0/1 wraps to a shift of 30/31, and 26-31 to 24-29: past the
  // mask, which correctly clears nothing.
  wire [25:2] consume_mask = (event_consume && !event_index[6] && !event_index[5]) ?
      (24'd1 << (event_index[4:0] - 5'd2)) : 24'd0;
  wire [7:0]  byte_consume = (event_consume && event_index[6]) ?
      (8'd1 << event_index[2:0]) : 8'd0;
  wire [31:0] sticky_view = {6'd0, sticky, 1'b1, 1'b0};
  // The controller sees level lines one cycle late (see px8_controller),
  // so no fabric path reaches its state in the same cycle.
  reg  event_level;
  wire event_ready = event_index[6] ? byte_sticky[event_index[2:0]] :
                     event_index[5] ? event_level :
                                      sticky_view[event_index[4:0]];

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      pulse_reg <= 24'd0;
      event_level <= 1'b0;
      sticky    <= 24'd0;
      byte_sticky <= 8'd0;
      flags     <= 2'd0;
      armed     <= 1'b0;
    end else begin
      pulse_reg <= pulse_next;
      event_level <= lines[{1'b1, event_index[4:0]}];
      sticky    <= clear_events ? 24'd0 :
                   ((sticky & ~consume_mask) | pulse_reg);
      byte_sticky <= clear_events ? 8'd0 :
                     ((byte_sticky & ~byte_consume) | byte_events);
      if (cfg_we && cfg_addr == 8'h30)
        flags <= cfg_data[1:0];
      if (cfg_we && cfg_addr == 8'h31)
        armed <= cfg_data[0];
    end
  end

  // ------------------------------------------------------------- contexts
  // Every timer, shifter, counter, logic cell and pin cell holds two
  // configurations (contexts). The active context follows a fabric line
  // (config 0x34: [5:0] line, [6] enable) two cycles later, so a protocol
  // phase change is one fabric event, with no controller and no rewrite.
  // Controller writes go to the contexts selected by 0x35 [1:0] ([0]
  // context 0, [1] context 1; reset: context 0 only). CRC and byte tiles
  // keep one configuration.
  reg [6:0]  context_cfg;
  reg [1:0]  write_bank;
  reg        context_pre;
  // The context active from the next cycle; each configuration register
  // keeps its active value in a register (config_bank), so this select
  // only reaches flip-flop inputs.
  wire       context_next = enable && context_pre;
  always @(posedge clk) begin
    if (!rst_n) begin
      context_cfg <= 7'd0;
      write_bank  <= 2'b01;
    end else if (cfg_we) begin
      if (cfg_addr == 8'h34)
        context_cfg <= cfg_data[6:0];
      if (cfg_addr == 8'h35)
        write_bank <= cfg_data[1:0];
    end
  end
  always @(posedge clk) begin
    if (!rst_n || !enable)
      context_pre <= 1'b0;
    else
      context_pre <= context_cfg[6] && lines[context_cfg[5:0]];
  end

  // Both shifters see the same signal values, including the same-cycle pins.
  wire [63:0] shifter_lines0 = lines;
  wire [63:0] shifter_lines1 = {lines[63:40], ~pin_sync_sh1_n, lines[31:0]};
  // Byte tiles are not cycle-critical, so they read the signal space a
  // cycle late through one shared register instead of loading every line
  // with 16 more selector inputs. Lines 0 and 1 are the constants.
  // Lines 26-31 are spare (constant 0) and are not registered.
  reg  [63:32] levels_q;
  reg  [25:2]  pulses_q;
  always @(posedge clk)
    if (!rst_n) begin
      levels_q <= 32'd0;
      pulses_q <= 24'd0;
    end else begin
      levels_q <= lines[63:32];
      pulses_q <= lines[25:2];
    end
  wire [63:0] tile_lines = {levels_q, 6'd0, pulses_q, 2'b10};

  // ---------------------------------------------------------- FIFO channels
  // Shifter k owns channel k through its byte tiles. The controller reaches
  // either channel. A shifter that auto-pulls owns its TX FIFO outright
  // (its stage-0 tile pulls from it), so the controller's PULL grant never
  // depends on fabric lines. On RX the controller's PUSH waits while a byte
  // is in flight from the shifter, so it never overtakes stream bytes;
  // bytes a tile holds until its packet ends are not in flight.
  wire [1:0]  sh_pulls, sh_tx_request, sh_rx_request, sh_tx_grant, sh_rx_grant;
  wire [15:0] sh_rx_byte;
  wire [15:0] sh_tx_byte;
  wire [1:0]  sh_tx_eop, sh_tx_err, sh_rx_eop, sh_rx_err;
  wire [1:0]  tile_tx_pop, rx_stream_valid, rx_in_flight;
  wire [19:0] rx_stream;
  wire [1:0]  cpu_select = cpu_channel ? 2'b10 : 2'b01;
  wire cpu_tx_grant = cpu_tx_request && |(cpu_select & ~sh_pulls & ~tx_empty);
  wire cpu_rx_grant = cpu_rx_request && |(cpu_select & ~rx_in_flight & ~rx_full);
  wire [1:0] rx_stream_push = rx_stream_valid & ~rx_full;
  assign tx_pop  = tile_tx_pop | (cpu_tx_grant ? cpu_select : 2'b00);
  assign rx_push = rx_stream_push | (cpu_rx_grant ? cpu_select : 2'b00);
  assign tx_push = cpu_tx_push ? cpu_select : 2'b00;
  assign tx_push_data = cpu_entry;
  assign rx_data = {rx_stream_push[1] ? rx_stream[19:10] : cpu_entry,
                    rx_stream_push[0] ? rx_stream[9:0]   : cpu_entry};

  genvar c;
  generate
    for (c = 0; c < 2; c = c + 1) begin : stream
      // Tile t = {channel, rx, stage}: TX stages 4c+0/1, RX stages 4c+2/3.
      wire [3:0] valid, ready, eop, err;
      wire [31:0] data;
      wire [9:0] head = tx_data[10*c +: 10];
      wire       tx_in_valid = sh_pulls[c] && !tx_empty[c];
      assign tile_tx_pop[c] = tx_in_valid && ready[0];
      wire [3:0] in_valid = {valid[2], sh_rx_request[c], valid[0], tx_in_valid};
      wire [31:0] in_data = {data[23:16], sh_rx_byte[8*c +: 8],
                             data[7:0], head[7:0]};
      wire [3:0] in_eop = {eop[2], sh_rx_eop[c], eop[0], head[8]};
      wire [3:0] in_err = {err[2], sh_rx_err[c], err[0], head[9]};
      wire [3:0] out_ready = {!rx_full[c], ready[3], sh_tx_grant[c], ready[1]};
      genvar s;
      for (s = 0; s < 4; s = s + 1) begin : tile
        byte_tile tile (
            .clk(clk), .rst_n(rst_n), .enable(live),
            .cfg_we(cfg_we && cfg_addr[7:5] == 3'b011 &&
                    cfg_addr[4:2] == 4 * c + s),
            .cfg_addr(cfg_addr[1:0]), .cfg_data(cfg_data),
            .lines(tile_lines),
            .in_valid(in_valid[s]), .in_data(in_data[8*s +: 8]),
            .in_eop(in_eop[s]), .in_err(in_err[s]), .in_ready(ready[s]),
            .out_valid(valid[s]), .out_data(data[8*s +: 8]),
            .out_eop(eop[s]), .out_err(err[s]), .out_ready(out_ready[s]),
            .event_pulse(byte_events[4 * c + s])
        );
      end
      assign sh_tx_grant[c] = sh_tx_request[c] && valid[1];
      assign sh_tx_byte[8*c +: 8] = data[15:8];
      assign sh_tx_eop[c] = eop[1];
      assign sh_tx_err[c] = err[1];
      assign sh_rx_grant[c] = sh_rx_request[c] && ready[2];
      assign rx_stream_valid[c] = valid[3];
      assign rx_stream[10*c +: 10] = {err[3], eop[3], data[31:24]};
      assign rx_in_flight[c] = sh_rx_request[c] || valid[2] || valid[3];
    end
  endgenerate

  px8_controller cpu (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .cfg_we(cpu_cfg_we),
      .cfg_addr(cpu_cfg_addr),
      .cfg_data(cpu_cfg_data),
      .rd_addr(rd_addr),
      .rd_data(rd_data),
      .event_ready(event_ready),
      .event_consume(event_consume),
      .event_index(event_index),
      .clear_events(clear_events),
      .fire(cpu_fire),
      .channel(cpu_channel),
      .tx_request(cpu_tx_request),
      .tx_grant(cpu_tx_grant),
      .tx_data(cpu_channel ? tx_data[19:10] : tx_data[9:0]),
      .tx_push(cpu_tx_push),
      .tx_space(!(cpu_channel ? tx_full[1] : tx_full[0])),
      .rx_request(cpu_rx_request),
      .rx_grant(cpu_rx_grant),
      .rx_data(cpu_rx_data),
      .push_eop(cpu_push_eop),
      .push_err(cpu_push_err),
      .halted(halted)
  );

  // ------------------------------------------------------------------ tiles
  genvar k;
  generate
    for (k = 0; k < 4; k = k + 1) begin : timer
      fabric_timer tile (
          .clk(clk), .rst_n(rst_n), .enable(live),
          .cfg_we(cfg_we && cfg_addr[7:4] == 4'h0 && cfg_addr[3:2] == k),
          .cfg_addr(cfg_addr[1:0]), .cfg_data(cfg_data),
          .cfg_bank(write_bank), .ctx_next(context_next),
          .lines(lines),
          .out(t_out[k]), .rise(t_rise[k]), .fall(t_fall[k])
      );
    end

    for (k = 0; k < 2; k = k + 1) begin : counter
      wire [7:0] count;
      fabric_counter tile (
          .clk(clk), .rst_n(rst_n), .enable(live),
          .cfg_we(cfg_we && cfg_addr[7:3] == 5'b00100 && cfg_addr[2] == k),
          .cfg_addr(cfg_addr[1:0]), .cfg_data(cfg_data[12:0]),
          .cfg_bank(write_bank), .ctx_next(context_next),
          .lines(lines),
          .ge(c_ge[k]), .hit(c_hit[k]), .count(count)
      );
    end

    // Logic cells drive the lines from their registers, like every tile.
    for (k = 0; k < 8; k = k + 1) begin : logic_cell
      fabric_logic tile (
          .clk(clk), .rst_n(rst_n), .enable(live),
          .cfg_we(cfg_we && cfg_addr[7:5] == 3'b010 && cfg_addr[4:2] == k),
          .cfg_addr(cfg_addr[1:0]), .cfg_data(cfg_data),
          .cfg_bank(write_bank), .ctx_next(context_next),
          .lines(lines), .q(logic_q[k])
      );
    end

    // Edge cells: their pulses are registered into the pulse lines.
    for (k = 0; k < 8; k = k + 1) begin : edge_cell
      fabric_edge tile (
          .clk(clk), .rst_n(rst_n),
          .cfg_we(cfg_we && cfg_addr == 8'h80 + k),
          .cfg_data(cfg_data[11:0]),
          .pin_now(pin_sync), .pin_prev(pin_prev), .levels(lines[63:32]),
          .pulse(edge_pulse[k])
      );
    end
  endgenerate

  wire [15:0] s_rx_data_0, s_rx_data_1, s_status_0, s_status_1;
  wire [1:0]  link_absorb, link_bit, link_emit;   // shifter -> CRC links
  wire [1:0]  crc_tail_out;                       // CRC -> shifter lookahead
  // Shifter k's registers: 0x10+4k..0x13+4k (regs 0-3), then 0x32+k,
  // 0x36+k and 0x38+k (regs 4, 5, 6).
  wire       sh_extra = cfg_addr == 8'h32 || cfg_addr == 8'h33 || cfg_addr == 8'h36 ||
                        cfg_addr == 8'h37 || cfg_addr == 8'h38 || cfg_addr == 8'h39;
  wire [2:0] sh_reg = cfg_addr[5] ? 3'd4 + {1'b0, cfg_addr[3:2]} : {1'b0, cfg_addr[1:0]};

  fabric_shifter shifter0 (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && (cfg_addr[7:2] == 6'b000100 || (sh_extra && !cfg_addr[0]))),
      .cfg_addr(sh_reg), .cfg_data(cfg_data),
      .cfg_bank(write_bank), .ctx_next(context_next),
      .lines(shifter_lines0),
      .pulls(sh_pulls[0]),
      .tx_request(sh_tx_request[0]), .tx_grant(sh_tx_grant[0]),
      .tx_data(sh_tx_byte[7:0]), .tx_eop(sh_tx_eop[0]), .tx_err(sh_tx_err[0]),
      .rx_request(sh_rx_request[0]), .rx_grant(sh_rx_grant[0]),
      .rx_byte(sh_rx_byte[7:0]), .rx_eop(sh_rx_eop[0]), .rx_err(sh_rx_err[0]),
      .crc_in(crc_tail_out[0]),
      .out(s_out[0]), .active(s_active[0]),
      .word_pulse(s_word[0]), .stop_pulse(s_stop[0]),
      .rx_data(s_rx_data_0), .status(s_status_0),
      .crc_absorb(link_absorb[0]), .crc_bit(link_bit[0]), .crc_emit(link_emit[0])
  );

  fabric_shifter shifter1 (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && (cfg_addr[7:2] == 6'b000101 || (sh_extra && cfg_addr[0]))),
      .cfg_addr(sh_reg), .cfg_data(cfg_data),
      .cfg_bank(write_bank), .ctx_next(context_next),
      .lines(shifter_lines1),
      .pulls(sh_pulls[1]),
      .tx_request(sh_tx_request[1]), .tx_grant(sh_tx_grant[1]),
      .tx_data(sh_tx_byte[15:8]), .tx_eop(sh_tx_eop[1]), .tx_err(sh_tx_err[1]),
      .rx_request(sh_rx_request[1]), .rx_grant(sh_rx_grant[1]),
      .rx_byte(sh_rx_byte[15:8]), .rx_eop(sh_rx_eop[1]), .rx_err(sh_rx_err[1]),
      .crc_in(crc_tail_out[1]),
      .out(s_out[1]), .active(s_active[1]),
      .word_pulse(s_word[1]), .stop_pulse(s_stop[1]),
      .rx_data(s_rx_data_1), .status(s_status_1),
      .crc_absorb(link_absorb[1]), .crc_bit(link_bit[1]), .crc_emit(link_emit[1])
  );

  // Two CRC tiles, so both directions of a link (or two links) can each
  // have one. Either can take its bits from lines or from either shifter's
  // coder link; shifter k's coder tail reads CRC k.
  wire [31:0] crc_value_0, crc_value_1;
  fabric_crc crc_tile (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && cfg_addr[7:3] == 5'b00101),
      .cfg_addr(cfg_addr[2:0]), .cfg_data(cfg_data),
      .lines(lines),
      .link_absorb(link_absorb), .link_bit(link_bit), .link_emit(link_emit),
      .out(crc_out[0]), .tail_out(crc_tail_out[0]),
      .ok(crc_ok[0]), .value(crc_value_0)
  );
  fabric_crc crc_tile_1 (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && cfg_addr[7:3] == 5'b10001),
      .cfg_addr(cfg_addr[2:0]), .cfg_data(cfg_data),
      .lines(lines),
      .link_absorb(link_absorb), .link_bit(link_bit), .link_emit(link_emit),
      .out(crc_out[1]), .tail_out(crc_tail_out[1]),
      .ok(crc_ok[1]), .value(crc_value_1)
  );

  // ------------------------------------------------------------- pin cells
  wire [63:0] pin_cfg;          // pin p: [8p +: 8]
  reg  [7:0]  out_q;
  reg  [7:0]  oe_q;
  genvar q;
  generate
    for (q = 0; q < 8; q = q + 1) begin : pin
      config_bank #(.WIDTH(8)) cfg (.clk(clk), .rst_n(rst_n),
          .we(cfg_we && cfg_addr == 8'h18 + q), .write_bank(write_bank),
          .data(cfg_data[7:0]), .ctx_next(context_next),
          .value(pin_cfg[8*q +: 8]), .next());
    end
  endgenerate

  reg [7:0] pin_value;
  integer m;
  always @(*) begin
    for (m = 0; m < 8; m = m + 1)
      pin_value[m] = pin_cfg[8*m + 5] ? pin_cfg[8*m + 4] : lines[{1'b1, pin_cfg[8*m +: 5]}];
  end

  // Every pin output is registered: one uniform cycle of output latency and
  // no glitches from the combinational source muxes.
  integer p;

  always @(posedge clk) begin
    if (!rst_n || !live) begin
      out_q <= 8'd0;
      oe_q  <= 8'd0;
    end else begin
      for (p = 0; p < 8; p = p + 1) begin
        case (pin_cfg[8*p + 6 +: 2])
          2'd0: begin out_q[p] <= 1'b0; oe_q[p] <= 1'b0; end
          2'd2: begin out_q[p] <= 1'b0; oe_q[p] <= !pin_value[p]; end
          default: begin out_q[p] <= pin_value[p]; oe_q[p] <= 1'b1; end
        endcase
      end
    end
  end
  assign gpio_out = out_q;
  assign gpio_oe  = oe_q;

  // -------------------------------------------------------------- readback
  always @(*) begin
    case (rd_addr)
      4'd0:  rd_data = {8'd0, pin_sync};
      4'd1:  rd_data = s_rx_data_0;
      4'd2:  rd_data = s_status_0;
      4'd3:  rd_data = s_rx_data_1;
      4'd4:  rd_data = s_status_1;
      4'd5:  rd_data = {8'd0, counter[0].count};
      4'd6:  rd_data = {8'd0, counter[1].count};
      4'd7:  rd_data = crc_value_0[15:0];
      4'd8:  rd_data = crc_value_0[31:16];
      4'd9:  rd_data = {sticky[15:2], 2'b10};
      4'd10: rd_data = {6'd0, sticky[25:16]};
      4'd11: rd_data = crc_value_1[15:0];
      4'd12: rd_data = crc_value_1[31:16];
      default: rd_data = 16'd0;
    endcase
  end
endmodule

`default_nettype wire
