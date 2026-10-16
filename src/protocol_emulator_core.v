`default_nettype none

// Spatial protocol engine. Bit-level behavior comes from a fabric of
// statically configured tiles that run every cycle without instruction
// fetch: 4 timers, 2 shifters, 2 counters, 1 CRC, 8 glue cells (LUT4+FF),
// and 8 pin cells. Every tile input is a 6-bit select into one 64-line
// signal space. A small PX8 controller configures the fabric and makes
// transaction-level decisions.
//
// Signal space (lines 2-31 are registered one-cycle pulses; the rest are
// levels):
//   0 zero   1 one   2-3 controller FIRE 0/1
//   4+2k / 5+2k   timer k rise / fall          (k = 0..3)
//   12+2k / 13+2k shifter k word / stop        (k = 0..1)
//   16+p / 24+p   pin p rise / fall (synchronized)
//   32+p          pin p level (synchronized)
//   40+k timer k out    44+k shifter k out    46+k shifter k active
//   48+k counter k >= threshold    50+k counter k hit (registered pulse)
//   52 CRC out bit   53 CRC matches check   54-55 controller flags 0/1
//   56+k glue cell k output
//
// Glue cells see each other only as registered values, so no configuration
// can form a loop and no combinational path crosses more than one glue
// cell.
//
// Config map (controller WCF address):
//   0x00-0x0F timer addr[3:2], reg addr[1:0]
//   0x10-0x17 shifter addr[2], reg addr[1:0]
//   0x18-0x1F pin p: [4:0] source level (signal space 32-63),
//             [5] controller pin, [7:6] mode: 0 input, 1 push-pull,
//             2 open-drain, 3 push-pull
//   0x20-0x27 counter addr[2], reg addr[1:0]
//   0x28-0x2E CRC reg addr[2:0]
//   0x30      controller flags [1:0]
//   0x31      [0] arm: tiles and pin outputs stay idle until armed, so a
//             partially written configuration can never act
//   0x32-0x33 shifter k burst register (shifter reg 4)

//   0x40-0x5F glue cell addr[4:2], reg addr[1:0]
//
// Readback map (controller RD address):
//   0 pins   1/3 shifter 0/1 rx data   2/4 shifter 0/1 status
//   5/6 counter 0/1 count   7/8 CRC [15:0]/[31:16]
//   9/10 sticky pulses [15:0]/[31:16]
module protocol_emulator_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    output wire [9:0] instruction_address,
    output wire       instruction_read,
    input  wire [7:0] instruction_data,
    // FIFO channel k = {TX FIFO k, RX FIFO k}, k = 0..1; bytes are packed
    // with channel 1 in the upper half.
    input  wire [15:0] tx_data,
    input  wire [1:0]  tx_empty,
    output wire [1:0]  tx_pop,
    input  wire [1:0]  tx_full,
    output wire [1:0]  tx_push,
    output wire [7:0]  tx_push_data,
    output wire [15:0] rx_data,
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
  reg [7:0] pin_prev;
  always @(posedge clk) begin
    if (!rst_n) begin
      pin_meta <= 8'd0;
      pin_sync <= 8'd0;
      pin_prev <= 8'd0;
    end else begin
      pin_meta <= gpio_in;
      pin_sync <= pin_meta;
      pin_prev <= pin_sync;
    end
  end

  // ------------------------------------------------------------- controller
  wire        cfg_we;
  wire [7:0]  cfg_addr;
  wire [15:0] cfg_data;
  wire [3:0]  rd_addr;
  reg  [15:0] rd_data;
  wire        event_consume;
  wire [5:0]  event_index;
  wire        clear_events;
  wire [1:0]  cpu_fire;
  wire        cpu_pin_we;
  wire [2:0]  cpu_pin_index;
  wire        cpu_pin_value;
  wire        cpu_channel;
  wire        cpu_tx_request;
  wire        cpu_rx_request;
  wire        cpu_tx_push;
  wire [7:0]  cpu_rx_data;

  // ------------------------------------------------------------ signal space
  wire [3:0]  t_out, t_rise, t_fall;
  wire [1:0]  s_out, s_active, s_word, s_stop;
  wire [1:0]  c_ge, c_hit;
  wire        crc_out, crc_ok;
  wire [7:0]  lut_out, lut_q;
  reg  [31:2] pulse_reg;
  reg  [1:0]  hit_reg;
  reg  [1:0]  flags;
  reg         armed;
  reg  [31:2] sticky;
  wire        live = enable && armed;

  wire [63:0] lines = {
      lut_out,                   // 63:56
      flags, crc_ok, crc_out,    // 55:52
      hit_reg, c_ge,             // 51:48
      s_active, s_out,           // 47:44
      t_out,                     // 43:40
      pin_sync,                  // 39:32
      pulse_reg, 1'b1, 1'b0      // 31:0
  };
  wire [31:2] pulse_next = {
      ~pin_sync & pin_prev,      // 31:24 pin fall
      pin_sync & ~pin_prev,      // 23:16 pin rise
      s_stop[1], s_word[1], s_stop[0], s_word[0],
      t_fall[3], t_rise[3], t_fall[2], t_rise[2],
      t_fall[1], t_rise[1], t_fall[0], t_rise[0],
      cpu_fire
  };
  // Index 0/1 wraps to a shift of 30/31, which correctly clears nothing.
  wire [31:2] consume_mask = (event_consume && !event_index[5]) ?
      (30'd1 << (event_index[4:0] - 5'd2)) : 30'd0;
  wire [31:0] sticky_view = {sticky, 1'b1, 1'b0};
  // The controller sees level lines one cycle late (see px8_controller),
  // so no fabric path reaches its state in the same cycle.
  reg  event_level;
  wire event_ready = event_index[5] ? event_level :
                                      sticky_view[event_index[4:0]];

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      pulse_reg <= 30'd0;
      event_level <= 1'b0;
      hit_reg   <= 2'd0;
      sticky    <= 30'd0;
      flags     <= 2'd0;
      armed     <= 1'b0;
    end else begin
      pulse_reg <= pulse_next;
      event_level <= lines[{1'b1, event_index[4:0]}];
      hit_reg   <= c_hit;
      sticky    <= clear_events ? 30'd0 :
                   ((sticky & ~consume_mask) | pulse_reg);
      if (cfg_we && cfg_addr == 8'h30)
        flags <= cfg_data[1:0];
      if (cfg_we && cfg_addr == 8'h31)
        armed <= cfg_data[0];
    end
  end

  // ---------------------------------------------------------- FIFO channels
  // Shifter k owns channel k. The controller reaches either channel. A
  // shifter that auto-pulls owns its TX FIFO outright, so the controller's
  // PULL grant never depends on fabric lines; on RX the controller yields
  // to a pending shifter push (a register).
  wire [1:0]  sh_pulls, sh_tx_request, sh_rx_request;
  wire [15:0] sh_rx_byte;
  wire [1:0]  sh_tx_grant = sh_tx_request & ~tx_empty;
  wire [1:0]  sh_rx_grant = sh_rx_request & ~rx_full;
  wire [1:0]  cpu_select = cpu_channel ? 2'b10 : 2'b01;
  wire cpu_tx_grant = cpu_tx_request && |(cpu_select & ~sh_pulls & ~tx_empty);
  wire cpu_rx_grant = cpu_rx_request && |(cpu_select & ~sh_rx_request & ~rx_full);
  assign tx_pop  = sh_tx_grant | (cpu_tx_grant ? cpu_select : 2'b00);
  assign rx_push = sh_rx_grant | (cpu_rx_grant ? cpu_select : 2'b00);
  assign tx_push = cpu_tx_push ? cpu_select : 2'b00;
  assign tx_push_data = cpu_rx_data;
  assign rx_data = {sh_rx_grant[1] ? sh_rx_byte[15:8] : cpu_rx_data,
                    sh_rx_grant[0] ? sh_rx_byte[7:0]  : cpu_rx_data};

  px8_controller cpu (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .cfg_we(cfg_we),
      .cfg_addr(cfg_addr),
      .cfg_data(cfg_data),
      .rd_addr(rd_addr),
      .rd_data(rd_data),
      .event_ready(event_ready),
      .event_consume(event_consume),
      .event_index(event_index),
      .clear_events(clear_events),
      .fire(cpu_fire),
      .pin_we(cpu_pin_we),
      .pin_index(cpu_pin_index),
      .pin_value(cpu_pin_value),
      .channel(cpu_channel),
      .tx_request(cpu_tx_request),
      .tx_grant(cpu_tx_grant),
      .tx_data(cpu_channel ? tx_data[15:8] : tx_data[7:0]),
      .tx_push(cpu_tx_push),
      .tx_space(!(cpu_channel ? tx_full[1] : tx_full[0])),
      .rx_request(cpu_rx_request),
      .rx_grant(cpu_rx_grant),
      .rx_data(cpu_rx_data),
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
          .lines(lines),
          .ge(c_ge[k]), .hit(c_hit[k]), .count(count)
      );
    end

    // Glue cells see each other's registered values only, which bounds the
    // combinational depth to one cell for any configuration.
    for (k = 0; k < 8; k = k + 1) begin : glue
      fabric_lut tile (
          .clk(clk), .rst_n(rst_n), .enable(live),
          .cfg_we(cfg_we && cfg_addr[7:5] == 3'b010 && cfg_addr[4:2] == k),
          .cfg_addr(cfg_addr[1:0]), .cfg_data(cfg_data),
          .lines({lut_q, lines[55:0]}),
          .out(lut_out[k]), .q(lut_q[k])
      );
    end
  endgenerate

  wire [15:0] s_rx_data_0, s_rx_data_1, s_status_0, s_status_1;

  fabric_shifter shifter0 (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && (cfg_addr[7:2] == 6'b000100 || cfg_addr == 8'h32)),
      .cfg_addr(cfg_addr[5] ? 3'd4 : {1'b0, cfg_addr[1:0]}), .cfg_data(cfg_data),
      .lines(lines),
      .pulls(sh_pulls[0]),
      .tx_request(sh_tx_request[0]), .tx_grant(sh_tx_grant[0]),
      .tx_data(tx_data[7:0]),
      .rx_request(sh_rx_request[0]), .rx_grant(sh_rx_grant[0]),
      .rx_byte(sh_rx_byte[7:0]),
      .out(s_out[0]), .active(s_active[0]),
      .word_pulse(s_word[0]), .stop_pulse(s_stop[0]),
      .rx_data(s_rx_data_0), .status(s_status_0)
  );

  fabric_shifter shifter1 (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && (cfg_addr[7:2] == 6'b000101 || cfg_addr == 8'h33)),
      .cfg_addr(cfg_addr[5] ? 3'd4 : {1'b0, cfg_addr[1:0]}), .cfg_data(cfg_data),
      .lines(lines),
      .pulls(sh_pulls[1]),
      .tx_request(sh_tx_request[1]), .tx_grant(sh_tx_grant[1]),
      .tx_data(tx_data[15:8]),
      .rx_request(sh_rx_request[1]), .rx_grant(sh_rx_grant[1]),
      .rx_byte(sh_rx_byte[15:8]),
      .out(s_out[1]), .active(s_active[1]),
      .word_pulse(s_word[1]), .stop_pulse(s_stop[1]),
      .rx_data(s_rx_data_1), .status(s_status_1)
  );

  wire [31:0] crc_value;
  fabric_crc crc_tile (
      .clk(clk), .rst_n(rst_n), .enable(live),
      .cfg_we(cfg_we && cfg_addr[7:3] == 5'b00101),
      .cfg_addr(cfg_addr[2:0]), .cfg_data(cfg_data),
      .lines(lines),
      .out(crc_out), .ok(crc_ok), .value(crc_value)
  );

  // ------------------------------------------------------------- pin cells
  reg [7:0] pin_cfg [0:7];
  reg [7:0] cpu_pins;
  reg [7:0] out_q;
  reg [7:0] oe_q;
  integer r;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (r = 0; r < 8; r = r + 1)
        pin_cfg[r] <= 8'd0;
    end else if (cfg_we && cfg_addr[7:3] == 5'b00011) begin
      pin_cfg[cfg_addr[2:0]] <= cfg_data[7:0];
    end
  end

  reg [7:0] pin_value;
  integer m;
  always @(*) begin
    for (m = 0; m < 8; m = m + 1)
      pin_value[m] = pin_cfg[m][5] ? cpu_pins[m] : lines[{1'b1, pin_cfg[m][4:0]}];
  end

  // Every pin output is registered: one uniform cycle of output latency and
  // no glitches from the combinational source muxes.
  integer p;
  always @(posedge clk) begin
    if (!rst_n || !enable)
      cpu_pins <= 8'd0;
    else if (cpu_pin_we)
      cpu_pins[cpu_pin_index] <= cpu_pin_value;
  end

  always @(posedge clk) begin
    if (!rst_n || !live) begin
      out_q <= 8'd0;
      oe_q  <= 8'd0;
    end else begin
      for (p = 0; p < 8; p = p + 1) begin
        case (pin_cfg[p][7:6])
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
      4'd7:  rd_data = crc_value[15:0];
      4'd8:  rd_data = crc_value[31:16];
      4'd9:  rd_data = {sticky[15:2], 2'b10};
      4'd10: rd_data = sticky[31:16];
      default: rd_data = 16'd0;
    endcase
  end
endmodule

`default_nettype wire
