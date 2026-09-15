/*
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Wraps the foundry 1024-by-8 single-port SRAM macro.
// Presents explicit read, write, and bit-mask controls.
// Keeps BIST pins inactive until a test controller is added.
module program_memory (
    input  wire       clk,
    input  wire       enable,
    input  wire       write_enable,
    input  wire       read_enable,
    input  wire [9:0] address,
    input  wire [7:0] write_data,
    input  wire [7:0] write_mask,
    output wire [7:0] read_data
);

  (* keep *) RM_IHPSG13_1P_1024x8_c2_bm_bist sram (
      .A_CLK(clk),
      .A_MEN(enable),
      .A_WEN(write_enable),
      .A_REN(read_enable),
      .A_ADDR(address),
      .A_DIN(write_data),
      .A_DLY(1'b1),
      .A_DOUT(read_data),
      .A_BM(write_mask),
      .A_BIST_CLK(1'b0),
      .A_BIST_EN(1'b0),
      .A_BIST_MEN(1'b0),
      .A_BIST_WEN(1'b0),
      .A_BIST_REN(1'b0),
      .A_BIST_ADDR(10'b0),
      .A_BIST_DIN(8'b0),
      .A_BIST_BM(8'b0)
  );

endmodule

`default_nettype wire
