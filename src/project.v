/*
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_protocol_emulator (
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

  // Two FIFO channels, one per shifter: channel k is TX FIFO k (host or
  // program -> engine) and RX FIFO k (engine -> host). The host reaches the
  // channel it last selected.
  wire host_channel;
  wire host_tx_push;
  wire [7:0] host_tx_push_data;
  wire host_rx_pop;
  wire [1:0] core_tx_push;
  wire [7:0] core_tx_push_data;
  wire [1:0] host_select = host_channel ? 2'b10 : 2'b01;
  // A running program may feed a TX FIFO itself (e.g. a frame stored in
  // SRAM); it has priority, so the host must not push to that channel then.
  wire [1:0] tx_push = (host_tx_push ? host_select : 2'b00) | core_tx_push;
  wire [1:0] tx_pop;
  wire [15:0] tx_pop_data;
  wire [1:0] tx_empty;
  wire [1:0] tx_full;
  wire [5:0] tx_level;

  wire [1:0] rx_push;
  wire [15:0] rx_push_data;
  wire [1:0] rx_pop = host_rx_pop ? host_select : 2'b00;
  wire [15:0] rx_pop_data;
  wire [1:0] rx_empty;
  wire [1:0] rx_full;
  wire [5:0] rx_level;

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
      .channel(host_channel),
      .tx_push(host_tx_push),
      .tx_push_data(host_tx_push_data),
      .tx_full(tx_full[host_channel]),
      .tx_level(host_channel ? tx_level[5:3] : tx_level[2:0]),
      .rx_pop(host_rx_pop),
      .rx_pop_data(host_channel ? rx_pop_data[15:8] : rx_pop_data[7:0]),
      .rx_empty(rx_empty[host_channel]),
      .rx_level(host_channel ? rx_level[5:3] : rx_level[2:0]),
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

  program_memory program_memory (
      .clk(clk),
      .enable(memory_enable),
      .write_enable(memory_write),
      .read_enable(memory_read),
      .address(memory_address),
      .write_data(host_program_write_data),
      .write_mask(host_program_write_mask),
      .read_data(program_read_data)
  );

  genvar k;
  generate
    for (k = 0; k < 2; k = k + 1) begin : channel
      byte_fifo tx_fifo (
          .clk(clk),
          .rst_n(internal_rst_n),
          .push(tx_push[k]),
          .push_data(core_tx_push[k] ? core_tx_push_data : host_tx_push_data),
          .pop(tx_pop[k]),
          .pop_data(tx_pop_data[8*k +: 8]),
          .empty(tx_empty[k]),
          .full(tx_full[k]),
          .level(tx_level[3*k +: 3])
      );

      byte_fifo rx_fifo (
          .clk(clk),
          .rst_n(internal_rst_n),
          .push(rx_push[k]),
          .push_data(rx_push_data[8*k +: 8]),
          .pop(rx_pop[k]),
          .pop_data(rx_pop_data[8*k +: 8]),
          .empty(rx_empty[k]),
          .full(rx_full[k]),
          .level(rx_level[3*k +: 3])
      );
    end
  endgenerate

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
      .tx_full(tx_full),
      .tx_push(core_tx_push),
      .tx_push_data(core_tx_push_data),
      .rx_data(rx_push_data),
      .rx_push(rx_push),
      .rx_full(rx_full),
      .gpio_in(uio_in),
      .gpio_out(uio_out),
      .gpio_oe(uio_oe),
      .halted(engine_halted)
  );

endmodule

`default_nettype wire
