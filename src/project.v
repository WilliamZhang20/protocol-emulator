/*
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_wzhang20_protocol_emulator (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
  wire internal_rst_n = rst_n && ena;

  wire engine_enable;
  wire engine_halted;
  wire host_program_enable;
  wire host_program_write;
  wire host_program_read;
  wire [9:0] host_program_address;
  wire [7:0] host_program_write_data;
  wire [7:0] host_program_write_mask;
  wire [7:0] program_read_data;

  wire [9:0] instruction_address;
  wire instruction_read;

  wire tx_push;
  wire [7:0] tx_push_data;
  wire tx_pop;
  wire [7:0] tx_pop_data;
  wire tx_empty;
  wire tx_full;
  wire [2:0] tx_level;

  wire rx_push;
  wire [7:0] rx_push_data;
  wire rx_pop;
  wire [7:0] rx_pop_data;
  wire rx_empty;
  wire rx_full;
  wire [2:0] rx_level;

  host_interface host (
      .clk(clk),
      .rst_n(internal_rst_n),
      .host_in(ui_in),
      .host_out(uo_out),
      .engine_enable(engine_enable),
      .program_enable(host_program_enable),
      .program_write(host_program_write),
      .program_read(host_program_read),
      .program_address(host_program_address),
      .program_write_data(host_program_write_data),
      .program_write_mask(host_program_write_mask),
      .program_read_data(program_read_data),
      .tx_push(tx_push),
      .tx_push_data(tx_push_data),
      .tx_full(tx_full),
      .rx_pop(rx_pop),
      .rx_pop_data(rx_pop_data),
      .rx_empty(rx_empty),
      .engine_halted(engine_halted)
  );

  wire memory_owned_by_engine = engine_enable;
  wire memory_enable = memory_owned_by_engine ? instruction_read :
                                               host_program_enable;
  wire memory_write = memory_owned_by_engine ? 1'b0 : host_program_write;
  wire memory_read = memory_owned_by_engine ? instruction_read :
                                             host_program_read;
  wire [9:0] memory_address = memory_owned_by_engine ? instruction_address :
                                                      host_program_address;

  (* keep_hierarchy *) program_memory program_memory (
      .clk(clk),
      .enable(memory_enable),
      .write_enable(memory_write),
      .read_enable(memory_read),
      .address(memory_address),
      .write_data(host_program_write_data),
      .write_mask(host_program_write_mask),
      .read_data(program_read_data)
  );

  byte_fifo tx_fifo (
      .clk(clk),
      .rst_n(internal_rst_n),
      .push(tx_push),
      .push_data(tx_push_data),
      .pop(tx_pop),
      .pop_data(tx_pop_data),
      .empty(tx_empty),
      .full(tx_full),
      .level(tx_level)
  );

  byte_fifo rx_fifo (
      .clk(clk),
      .rst_n(internal_rst_n),
      .push(rx_push),
      .push_data(rx_push_data),
      .pop(rx_pop),
      .pop_data(rx_pop_data),
      .empty(rx_empty),
      .full(rx_full),
      .level(rx_level)
  );

  protocol_emulator_core core (
      .clk(clk),
      .rst_n(internal_rst_n),
      .enable(engine_enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(program_read_data),
      .tx_data(tx_pop_data),
      .tx_empty(tx_empty),
      .tx_pop(tx_pop),
      .rx_data(rx_push_data),
      .rx_push(rx_push),
      .rx_full(rx_full),
      .gpio_in(uio_in),
      .gpio_out(uio_out),
      .gpio_oe(uio_oe),
      .halted(engine_halted)
  );

  wire _unused = &{tx_level, rx_level, 1'b0};
endmodule

`default_nettype wire
