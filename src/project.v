/*
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Provides the Tiny Tapeout shell for the protocol emulator.
// Separates host pins from the bidirectional protocol pins.
// Leaves behavior to the SRAM-programmed core added later.
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

  wire [7:0] _program_rdata;

  (* keep_hierarchy *) program_memory program_memory (
      .clk(clk),
      .enable(1'b0),
      .write_enable(1'b0),
      .read_enable(1'b0),
      .address(10'b0),
      .write_data(8'b0),
      .write_mask(8'b0),
      .read_data(_program_rdata)
  );

  assign uo_out = 8'b0;
  assign uio_out = 8'b0;
  assign uio_oe = 8'b0;

  wire _unused = &{ui_in, uio_in, ena, rst_n, _program_rdata, 1'b0};

endmodule

`default_nettype wire
