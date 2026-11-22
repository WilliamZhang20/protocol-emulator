`default_nettype none

// First vertical slice, not a complete general-purpose fabric. Each tile's
// registered ports are connected by the finite links in spi_fabric below.
module proto_timer(input wire clk, input wire rst_n, input wire run,
                   input wire [7:0] half_period,
                   output reg level, output reg rise, output reg fall);
  reg [7:0] count;
  always @(posedge clk) begin
    if (!rst_n || !run) begin count <= 0; level <= 0; rise <= 0; fall <= 0; end
    else begin
      rise <= 0; fall <= 0;
      if (count == half_period - 1'b1) begin
        count <= 0; level <= !level;
        if (level) fall <= 1; else rise <= 1;
      end else count <= count + 1'b1;
    end
  end
endmodule

// One TX and RX word, MSB first. Width is a runtime configuration value in
// the range 1..8; values above 8 are rejected by the surrounding prototype.
module proto_shift(input wire clk, input wire rst_n, input wire start,
                   input wire rise, input wire fall, input wire serial_in,
                   input wire [7:0] tx_word, input wire [3:0] width,
                   output wire serial_out, output reg busy, output reg done,
                   output reg [7:0] rx_word);
  reg [7:0] tx_shift;
  reg [3:0] count;
  assign serial_out = tx_shift[7];
  always @(posedge clk) begin
    if (!rst_n) begin tx_shift <= 0; rx_word <= 0; count <= 0; busy <= 0; done <= 0; end
    else begin
      done <= 0;
      if (start && !busy) begin
        tx_shift <= tx_word; rx_word <= 0; count <= 0; busy <= 1;
      end else if (busy) begin
        if (rise) begin rx_word <= {rx_word[6:0], serial_in}; count <= count + 1'b1; end
        if (fall) begin
          if (count == width) begin busy <= 0; done <= 1; end
          else tx_shift <= {tx_shift[6:0], 1'b0};
        end
      end
    end
  end
endmodule

// This is an intentionally fixed SPI phase sequencer, not yet a configurable
// control tile. It supplies a concrete benchmark while that design is open.
module proto_spi_control(input wire clk, input wire rst_n, input wire arm,
                         input wire trigger, input wire shift_done,
                         output reg selected, output reg shift_start,
                         output reg done);
  localparam IDLE=2'd0, START=2'd1, TRANSFER=2'd2, FINISHED=2'd3;
  reg [1:0] state;
  always @(posedge clk) begin
    if (!rst_n || !arm) begin state <= IDLE; selected <= 0; shift_start <= 0; done <= 0; end
    else begin
      shift_start <= 0;
      case (state)
        IDLE: if (trigger) begin selected <= 1; state <= START; done <= 0; end
        START: begin shift_start <= 1; state <= TRANSFER; end
        TRANSFER: if (shift_done) begin selected <= 0; done <= 1; state <= FINISHED; end
        FINISHED: if (!trigger) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule

module proto_pin_out(input wire clk, input wire rst_n, input wire arm,
                     input wire value, output reg pin, output reg oe);
  always @(posedge clk) begin
    if (!rst_n || !arm) begin pin <= 0; oe <= 0; end
    else begin pin <= value; oe <= 1; end
  end
endmodule

module proto_pin_in(input wire clk, input wire rst_n, input wire pin,
                    output reg sync_pin);
  reg meta;
  always @(posedge clk) begin
    if (!rst_n) begin meta <= 0; sync_pin <= 0; end
    else begin meta <= pin; sync_pin <= meta; end
  end
endmodule

// Four-choice registered, directed junction. Each output is independent;
// static selectors decide which of its four physical inputs it samples.
module proto_route(input wire clk, input wire rst_n, input wire [1:0] select,
                   input wire [3:0] sources, output reg out);
  always @(posedge clk)
    if (!rst_n) out <= 0; else out <= sources[select];
endmodule

// Two configuration words, written while disarmed. Both must be written
// before arm; writes while armed are ignored. Address 0: {4'b0,width[3:0],
// half_period[7:0]}; address 1: eight two-bit route selectors. Each route has
// exactly the four listed inputs; this is not an all-to-all crossbar.
module spi_fabric #(parameter FIXED_ROUTES = 0)(input wire clk, input wire rst_n, input wire arm,
                  input wire cfg_we, input wire cfg_addr, input wire [15:0] cfg_data,
                  input wire trigger, input wire [7:0] tx_word,
                  input wire miso, output wire cs, output wire sck,
                  output wire mosi, output wire [2:0] oe,
                  output wire done, output wire [7:0] rx_word);
  reg [7:0] half_period;
  reg [3:0] width;
  reg [15:0] routes;
  wire [15:0] active_routes = FIXED_ROUTES ? 16'd0 : routes;
  reg [1:0] cfg_written;
  always @(posedge clk) begin
    if (!rst_n) begin
      half_period <= 0; width <= 0; routes <= 0; cfg_written <= 0;
    end else if (!arm && cfg_we) begin
      if (!cfg_addr) begin
        half_period <= cfg_data[7:0]; width <= cfg_data[11:8]; cfg_written[0] <= 1;
      end else begin routes <= cfg_data; cfg_written[1] <= 1; end
    end
  end
  wire selected, shift_start, shift_busy, shift_done;
  wire timer_level, timer_rise, timer_fall, serial_out, serial_in, routed_serial;
  wire routed_start, routed_run, routed_rise, routed_fall, routed_in, routed_cs, routed_sck;
  wire valid = &cfg_written && half_period >= 4 && width >= 1 && width <= 8;
  wire running_reset_n = rst_n && arm && valid;
  proto_spi_control control(clk, rst_n, arm && valid, trigger, shift_done,
                            selected, shift_start, done);
  proto_timer timer(clk, running_reset_n, routed_run, half_period,
                    timer_level, timer_rise, timer_fall);
  proto_shift shifter(clk, running_reset_n, routed_start, routed_rise, routed_fall,
                      routed_in, tx_word, width, serial_out, shift_busy,
                      shift_done, rx_word);
  proto_pin_in miso_pin(clk, rst_n, miso, serial_in);
  proto_route start_route(clk, running_reset_n, active_routes[1:0], {timer_rise, trigger, 1'b0, shift_start}, routed_start);
  proto_route run_route(clk, running_reset_n, active_routes[3:2], {1'b1, 1'b0, selected, shift_busy}, routed_run);
  proto_route rise_route(clk, running_reset_n, active_routes[5:4], {trigger, 1'b0, timer_fall, timer_rise}, routed_rise);
  proto_route fall_route(clk, running_reset_n, active_routes[7:6], {trigger, 1'b0, timer_rise, timer_fall}, routed_fall);
  proto_route input_route(clk, running_reset_n, active_routes[9:8], {serial_out, 1'b1, 1'b0, serial_in}, routed_in);
  proto_route mosi_route(clk, running_reset_n, active_routes[11:10], {1'b1, 1'b0, timer_level, serial_out}, routed_serial);
  proto_route sck_route(clk, running_reset_n, active_routes[13:12], {1'b1, 1'b0, serial_out, timer_level}, routed_sck);
  proto_route cs_route(clk, running_reset_n, active_routes[15:14], {1'b1, 1'b0, selected, !selected}, routed_cs);
  proto_pin_out cs_pin(clk, rst_n, arm && valid, routed_cs, cs, oe[0]);
  proto_pin_out sck_pin(clk, rst_n, arm && valid, routed_sck, sck, oe[1]);
  proto_pin_out mosi_pin(clk, rst_n, arm && valid, routed_serial, mosi, oe[2]);
endmodule

// Identical tiles/timing but the route configuration word is always zero.
// This gives synthesis a same-workload fixed-routing control; it does not
// model the existing chip's global interconnect.
module spi_fixed_routes(input wire clk, input wire rst_n, input wire arm,
                        input wire cfg_we, input wire cfg_addr, input wire [15:0] cfg_data,
                        input wire trigger, input wire [7:0] tx_word,
                        input wire miso, output wire cs, output wire sck,
                        output wire mosi, output wire [2:0] oe,
                        output wire done, output wire [7:0] rx_word);
  wire [15:0] fixed_data = cfg_addr ? 16'd0 : cfg_data;
  spi_fabric #(.FIXED_ROUTES(1)) fabric(clk, rst_n, arm, cfg_we, cfg_addr, fixed_data, trigger,
                    tx_word, miso, cs, sck, mosi, oe, done, rx_word);
endmodule
`default_nettype wire
