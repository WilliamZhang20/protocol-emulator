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

// One TX and RX word, MSB first. Width is a configured value in 1..16.
// TX data is left aligned; captured RX data is right aligned.
module proto_shift(input wire clk, input wire rst_n, input wire start,
                   input wire rise, input wire fall, input wire serial_in,
                   input wire [15:0] tx_word, input wire [4:0] width,
                   output wire serial_out, output reg busy, output reg done,
                   output reg [15:0] rx_word);
  reg [15:0] tx_shift;
  reg [4:0] count;
  assign serial_out = tx_shift[15];
  always @(posedge clk) begin
    if (!rst_n) begin tx_shift <= 0; rx_word <= 0; count <= 0; busy <= 0; done <= 0; end
    else begin
      done <= 0;
      if (start && !busy) begin
        tx_shift <= tx_word; rx_word <= 0; count <= 0; busy <= 1;
      end else if (busy) begin
        if (rise) begin rx_word <= {rx_word[14:0], serial_in}; count <= count + 1'b1; end
        if (fall) begin
          if (count == width) begin busy <= 0; done <= 1; end
          else tx_shift <= {tx_shift[14:0], 1'b0};
        end
      end
    end
  end
endmodule

// Configurable 4-state, 2-input Mealy table. Each row is
// {done, shift_start, selected, next_state[1:0]}; row address is
// {state[1:0], trigger, shift_done}. Configuration writes are only accepted
// while the surrounding fabric is disarmed. Outputs are registered.
module proto_control(input wire clk, input wire rst_n, input wire arm,
                     input wire cfg_we, input wire [3:0] cfg_row,
                     input wire [4:0] cfg_data,
                     input wire trigger, input wire shift_done,
                     output reg selected, output reg shift_start,
                     output reg done);
  reg [4:0] table_rows [0:15];
  reg [1:0] state;
  wire [3:0] row = {state, trigger, shift_done};
  wire [4:0] transition = table_rows[row];
  always @(posedge clk)
    if (cfg_we) table_rows[cfg_row] <= cfg_data;
  always @(posedge clk) begin
    if (!rst_n || !arm) begin state <= 0; selected <= 0; shift_start <= 0; done <= 0; end
    else begin
      state <= transition[1:0];
      selected <= transition[2];
      shift_start <= transition[3];
      done <= transition[4];
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

// Local four-word register-file prototype, not an SRAM macro. Host writes
// are accepted only while disarmed; the shifter writes completed RX to word
// 1 while armed. Word 0 feeds TX. Host read is combinational and valid bits
// prevent uninitialized words being mistaken for payload.
module proto_local_store(input wire clk, input wire rst_n, input wire arm,
                         input wire host_we, input wire [1:0] host_addr,
                         input wire [15:0] host_wdata,
                         input wire start, input wire capture, input wire [15:0] capture_data,
                         output wire [15:0] tx_data, output wire tx_valid,
                         output wire [15:0] host_rdata, output wire host_rvalid);
  reg [15:0] words [0:3];
  reg [3:0] word_valid;
  assign tx_data = words[0];
  assign tx_valid = word_valid[0];
  assign host_rdata = words[host_addr];
  assign host_rvalid = word_valid[host_addr];
  always @(posedge clk) begin
    if (!rst_n) word_valid <= 0;
    else if (!arm && host_we) begin
      words[host_addr] <= host_wdata; word_valid[host_addr] <= 1;
    end else if (arm && start) word_valid[1] <= 0;
    else if (arm && capture) begin
      words[1] <= capture_data; word_valid[1] <= 1;
    end
  end
endmodule

// Eighteen configuration words, written while disarmed. Address 0 sets
// {3'b0,width[4:0],half_period[7:0]}, address 1 the route selectors, and
// addresses 2..17 the 16 control rows. All must be written before arm.
// Writes while armed and addresses 18..31 are ignored. Each route has
// exactly the four listed inputs; this is not an all-to-all crossbar.
module spi_fabric #(parameter FIXED_ROUTES = 0)(input wire clk, input wire rst_n, input wire arm,
                  input wire cfg_we, input wire [4:0] cfg_addr, input wire [15:0] cfg_data,
                  input wire trigger, input wire host_we, input wire [1:0] host_addr,
                  input wire [15:0] host_wdata, output wire [15:0] host_rdata,
                  output wire host_rvalid,
                  input wire miso, output wire cs, output wire sck,
                  output wire mosi, output wire [2:0] oe,
                  output wire done, output wire [15:0] rx_word);
  reg [7:0] half_period;
  reg [4:0] width;
  reg [15:0] routes;
  wire [15:0] active_routes = FIXED_ROUTES ? 16'd0 : routes;
  reg [17:0] cfg_written;
  wire control_write = rst_n && !arm && cfg_we && cfg_addr >= 5'd2 && cfg_addr <= 5'd17;
  wire [4:0] control_row_addr = cfg_addr - 5'd2;
  always @(posedge clk) begin
    if (!rst_n) begin
      half_period <= 0; width <= 0; routes <= 0; cfg_written <= 0;
    end else if (!arm && cfg_we) begin
      if (cfg_addr == 0) begin
        half_period <= cfg_data[7:0]; width <= cfg_data[12:8]; cfg_written[0] <= 1;
      end else if (cfg_addr == 1) begin routes <= cfg_data; cfg_written[1] <= 1; end
      else if (cfg_addr <= 17) cfg_written[cfg_addr] <= 1;
    end
  end
  wire selected, shift_start, shift_busy, shift_done;
  wire [15:0] tx_word;
  wire tx_valid;
  wire timer_level, timer_rise, timer_fall, serial_out, serial_in, routed_serial;
  wire routed_start, routed_run, routed_rise, routed_fall, routed_in, routed_cs, routed_sck;
  wire valid = &cfg_written && tx_valid && half_period >= 4 && width >= 1 && width <= 16;
  wire running_reset_n = rst_n && arm && valid;
  proto_control control(clk, rst_n, arm && valid, control_write, control_row_addr[3:0], cfg_data[4:0],
                        trigger, shift_done, selected, shift_start, done);
  proto_local_store data_store(clk, rst_n, arm, host_we, host_addr, host_wdata,
                               routed_start, shift_done, rx_word, tx_word, tx_valid, host_rdata, host_rvalid);
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
                        input wire cfg_we, input wire [4:0] cfg_addr, input wire [15:0] cfg_data,
                        input wire trigger, input wire host_we, input wire [1:0] host_addr,
                        input wire [15:0] host_wdata, output wire [15:0] host_rdata,
                        output wire host_rvalid,
                        input wire miso, output wire cs, output wire sck,
                        output wire mosi, output wire [2:0] oe,
                        output wire done, output wire [15:0] rx_word);
  wire [15:0] fixed_data = cfg_addr == 1 ? 16'd0 : cfg_data;
  spi_fabric #(.FIXED_ROUTES(1)) fabric(clk, rst_n, arm, cfg_we, cfg_addr, fixed_data, trigger,
                    host_we, host_addr, host_wdata, host_rdata, host_rvalid,
                    miso, cs, sck, mosi, oe, done, rx_word);
endmodule
`default_nettype wire
