`default_nettype none

// Spatial protocol engine. Bit-level timing is produced by a fabric of
// statically configured tiles (4 timers, 2 shifters, 8 pin cells) that run
// every cycle without instruction fetch. Tiles talk over a registered
// 32-line event bus: every hop costs exactly one cycle, and no configuration
// can form a combinational loop. A small PX8 controller configures the
// fabric and makes transaction-level decisions.
//
// Event bus (index = 5-bit select used by every tile):
//   0 never   1 always   2-3 CPU FIRE 0/1
//   4+2k / 5+2k  timer k rise / fall (k = 0..3)
//   12/13 shifter 0 start/done   14/15 shifter 1 start/done
//   16+p / 24+p  pin p rise / fall (synchronized)
//
// Config map (controller WCF address):
//   0x00-0x0F timer k = addr[3:2], register addr[1:0]
//   0x10-0x17 shifter k = addr[2], register addr[1:0]
//   0x18-0x1F pin p = addr[2:0]: [2:0] source, [4:3] mode
//     source: 0 CPU, 1-4 timer 0-3, 5 shifter 0, 6 shifter 1, 7 zero
//     mode:   0 input, 1 push-pull, 2 open-drain, 3 push-pull
//
// Readback map (controller RD address):
//   0 pins   1/3 shifter 0/1 rx data   2/4 shifter 0/1 status
//   5 timers running   6/7 sticky events [15:0]/[31:16]
module protocol_emulator_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    output wire [9:0] instruction_address,
    output wire       instruction_read,
    input  wire [7:0] instruction_data,
    input  wire [7:0] tx_data,
    input  wire       tx_empty,
    output wire       tx_pop,
    output wire [7:0] rx_data,
    output wire       rx_push,
    input  wire       rx_full,
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
  wire [2:0]  rd_addr;
  reg  [15:0] rd_data;
  wire        event_consume;
  wire [4:0]  event_index;
  wire        clear_events;
  wire [1:0]  cpu_fire;
  wire        cpu_pin_we;
  wire [2:0]  cpu_pin_index;
  wire        cpu_pin_value;
  wire        cpu_tx_request;
  wire        cpu_rx_request;
  wire [7:0]  cpu_rx_data;
  reg  [31:2] event_reg;
  wire [31:0] events = {event_reg, 1'b1, 1'b0};
  // Lines 0/1 are constants, so only lines 2-31 need sticky flags.
  reg  [31:2] sticky_reg;
  wire [31:0] sticky = {sticky_reg, 1'b1, 1'b0};

  // ------------------------------------------------------------- arbitration
  // Fixed priority, shifter 0 > shifter 1 > CPU. Ownership is normally
  // static (one consumer per FIFO), so priority only matters if a program
  // deliberately shares a queue.
  wire [1:0] sh_tx_request;
  wire [1:0] sh_rx_request;
  wire [7:0] sh_rx_byte_0;
  wire [7:0] sh_rx_byte_1;
  wire [1:0] sh_tx_grant;
  wire [1:0] sh_rx_grant;
  wire       cpu_tx_grant;
  wire       cpu_rx_grant;
  assign sh_tx_grant[0] = sh_tx_request[0] && !tx_empty;
  assign sh_tx_grant[1] = sh_tx_request[1] && !sh_tx_request[0] && !tx_empty;
  assign cpu_tx_grant   = cpu_tx_request && !(|sh_tx_request) && !tx_empty;
  assign sh_rx_grant[0] = sh_rx_request[0] && !rx_full;
  assign sh_rx_grant[1] = sh_rx_request[1] && !sh_rx_request[0] && !rx_full;
  assign cpu_rx_grant   = cpu_rx_request && !(|sh_rx_request) && !rx_full;
  assign tx_pop  = |{sh_tx_grant, cpu_tx_grant};
  assign rx_push = |{sh_rx_grant, cpu_rx_grant};
  assign rx_data = sh_rx_grant[0] ? sh_rx_byte_0 :
                   sh_rx_grant[1] ? sh_rx_byte_1 : cpu_rx_data;

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
      .event_ready(sticky[event_index]),
      .event_consume(event_consume),
      .event_index(event_index),
      .clear_events(clear_events),
      .fire(cpu_fire),
      .pin_we(cpu_pin_we),
      .pin_index(cpu_pin_index),
      .pin_value(cpu_pin_value),
      .tx_request(cpu_tx_request),
      .tx_grant(cpu_tx_grant),
      .tx_data(tx_data),
      .rx_request(cpu_rx_request),
      .rx_grant(cpu_rx_grant),
      .rx_data(cpu_rx_data),
      .halted(halted)
  );

  // ------------------------------------------------------------------ tiles
  wire [3:0] t_out;
  wire [3:0] t_rise;
  wire [3:0] t_fall;
  wire [3:0] t_running;
  genvar k;
  generate
    for (k = 0; k < 4; k = k + 1) begin : timer
      fabric_timer tile (
          .clk(clk),
          .rst_n(rst_n),
          .enable(enable),
          .cfg_we(cfg_we && cfg_addr[7:4] == 4'h0 && cfg_addr[3:2] == k),
          .cfg_addr(cfg_addr[1:0]),
          .cfg_data(cfg_data),
          .events(events),
          .pins(pin_sync),
          .out(t_out[k]),
          .rise(t_rise[k]),
          .fall(t_fall[k]),
          .running(t_running[k])
      );
    end
  endgenerate

  wire [1:0]  s_out;
  wire [1:0]  s_start;
  wire [1:0]  s_done;
  wire [15:0] s_rx_data_0, s_rx_data_1;
  wire [15:0] s_status_0, s_status_1;

  fabric_shifter shifter0 (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .cfg_we(cfg_we && cfg_addr[7:2] == 6'b000100),
      .cfg_addr(cfg_addr[1:0]),
      .cfg_data(cfg_data),
      .events(events),
      .pins(pin_sync),
      .tx_request(sh_tx_request[0]),
      .tx_grant(sh_tx_grant[0]),
      .tx_data(tx_data),
      .rx_request(sh_rx_request[0]),
      .rx_grant(sh_rx_grant[0]),
      .rx_byte(sh_rx_byte_0),
      .out(s_out[0]),
      .start_pulse(s_start[0]),
      .done_pulse(s_done[0]),
      .rx_data(s_rx_data_0),
      .status(s_status_0)
  );

  fabric_shifter shifter1 (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .cfg_we(cfg_we && cfg_addr[7:2] == 6'b000101),
      .cfg_addr(cfg_addr[1:0]),
      .cfg_data(cfg_data),
      .events(events),
      .pins(pin_sync),
      .tx_request(sh_tx_request[1]),
      .tx_grant(sh_tx_grant[1]),
      .tx_data(tx_data),
      .rx_request(sh_rx_request[1]),
      .rx_grant(sh_rx_grant[1]),
      .rx_byte(sh_rx_byte_1),
      .out(s_out[1]),
      .start_pulse(s_start[1]),
      .done_pulse(s_done[1]),
      .rx_data(s_rx_data_1),
      .status(s_status_1)
  );

  // -------------------------------------------------------------- event bus
  wire [31:2] events_next = {
      ~pin_sync & pin_prev,                       // 31:24 pin fall
      pin_sync & ~pin_prev,                       // 23:16 pin rise
      s_done[1], s_start[1], s_done[0], s_start[0],
      t_fall[3], t_rise[3], t_fall[2], t_rise[2],
      t_fall[1], t_rise[1], t_fall[0], t_rise[0],
      cpu_fire
  };
  // Index 0/1 wraps to a shift of 30/31, which correctly clears nothing.
  wire [31:2] consume_mask = event_consume ?
      (30'd1 << (event_index - 5'd2)) : 30'd0;
  wire [31:2] sticky_next = clear_events ? 30'd0 :
      ((sticky_reg & ~consume_mask) | event_reg);
  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      event_reg  <= 30'd0;
      sticky_reg <= 30'd0;
    end else begin
      event_reg <= events_next;
      sticky_reg <= sticky_next;
    end
  end

  // ------------------------------------------------------------- pin cells
  reg [4:0] pin_cfg [0:7];
  reg [7:0] cpu_pins;
  reg [7:0] out_q;
  reg [7:0] oe_q;
  integer p;
  integer r;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (r = 0; r < 8; r = r + 1)
        pin_cfg[r] <= 5'd0;
    end else if (cfg_we && cfg_addr[7:3] == 5'b00011) begin
      pin_cfg[cfg_addr[2:0]] <= cfg_data[4:0];
    end
  end

  reg [7:0] pin_value;
  integer m;
  always @(*) begin
    for (m = 0; m < 8; m = m + 1) begin
      case (pin_cfg[m][2:0])
        3'd0: pin_value[m] = cpu_pins[m];
        3'd1: pin_value[m] = t_out[0];
        3'd2: pin_value[m] = t_out[1];
        3'd3: pin_value[m] = t_out[2];
        3'd4: pin_value[m] = t_out[3];
        3'd5: pin_value[m] = s_out[0];
        3'd6: pin_value[m] = s_out[1];
        default: pin_value[m] = 1'b0;
      endcase
    end
  end

  // Every pin output is registered: one uniform cycle of output latency and
  // no glitches from the combinational source muxes.
  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      cpu_pins <= 8'd0;
      out_q    <= 8'd0;
      oe_q     <= 8'd0;
    end else begin
      if (cpu_pin_we)
        cpu_pins[cpu_pin_index] <= cpu_pin_value;
      for (p = 0; p < 8; p = p + 1) begin
        case (pin_cfg[p][4:3])
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
      3'd0: rd_data = {8'd0, pin_sync};
      3'd1: rd_data = s_rx_data_0;
      3'd2: rd_data = s_status_0;
      3'd3: rd_data = s_rx_data_1;
      3'd4: rd_data = s_status_1;
      3'd5: rd_data = {12'd0, t_running};
      3'd6: rd_data = sticky[15:0];
      default: rd_data = sticky[31:16];
    endcase
  end

endmodule

`default_nettype wire
