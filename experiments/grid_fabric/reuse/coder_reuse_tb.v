`timescale 1ns/1ps
`default_nettype none
// Isolated reuse probe: old general-purpose coded shifter and CRC, exposed as
// ports. It is not the grid top and does not claim protocol compilation.
module coder_reuse_tb(
 input wire clk,rst_n,enable,
 input wire shift_cfg_we, input wire [2:0] shift_cfg_addr,input wire [15:0] shift_cfg_data,
 input wire crc_cfg_we,input wire [2:0] crc_cfg_addr,input wire [15:0] crc_cfg_data,
 input wire [63:0] lines,input wire tx_grant,input wire [7:0] tx_data,input wire tx_eop,
 output wire tx_request,serial,active,word_pulse,stop_pulse);
 wire pulls,rx_request,rx_eop,rx_err,crc_out,crc_tail,crc_ok;
 wire [7:0] rx_byte;wire [15:0] rx_data,status;wire [31:0] crc_value;
 wire absorb,bit_data,emit;
 fabric_shifter shift(clk,rst_n,enable,shift_cfg_we,shift_cfg_addr,shift_cfg_data,2'b11,1'b0,
   lines,pulls,tx_request,tx_grant,tx_data,tx_eop,1'b0,rx_request,1'b0,crc_tail,
   rx_byte,rx_eop,rx_err,serial,active,word_pulse,stop_pulse,rx_data,status,absorb,bit_data,emit,1'b1);
 fabric_crc crc(clk,rst_n,enable,crc_cfg_we,crc_cfg_addr,crc_cfg_data,lines,
   {1'b0,absorb},{1'b0,bit_data},{1'b0,emit},crc_out,crc_tail,crc_ok,crc_value);
endmodule
`default_nettype wire
