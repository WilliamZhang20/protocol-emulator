/* SPDX-License-Identifier: Apache-2.0 */
`default_nettype none
// Experimental unified SPI / UART fabric. The host command link uses ui_in as
// data, uio[4:2] as opcode and uio[1] as strobe; uio[0] is serial input.
module tt_um_protocol_emulator (
    input wire [7:0] ui_in, output wire [7:0] uo_out,
    input wire [7:0] uio_in, output wire [7:0] uio_out,
    output wire [7:0] uio_oe, input wire ena, input wire clk, input wire rst_n
);
  wire reset_n=rst_n && ena;
  reg sync1,sync2,strobe_prev;
  wire command=sync2 && !strobe_prev;
  reg arm,host_req,host_we,cfg_mode,uart_mode;
  reg [9:0] host_addr;
  reg [7:0] host_wdata,read_data,source_addr,dest_addr,cfg_low;
  reg [10:0] tx_length,rx_capacity;
  reg start;
  wire host_ready,host_rvalid,configured,tx_done,tx_error,rx_overflow,tx_active;
  wire spi_done,spi_error,spi_active;
  wire [10:0] rx_received,rx_written;
  wire [2:0] pins,pin_oe,tx_queued,rx_queued;
  wire [7:0] host_rdata;
  wire cfg_write=command && uio_in[4:2]==3'd4 && !arm && !ui_in[2];
  wire image_write=command && uio_in[4:2]==3'd7 && !arm && cfg_mode;
  wire [15:0] image_word={ui_in,cfg_low};
  fabric_v2_unified #(.USE_MACRO(1)) fabric(
      .clk(clk),.rst_n(reset_n),.arm(arm),.cfg_we(image_write),.cfg_addr(host_addr[4:0]),.cfg_data(image_word),
      .bank_cfg_we(cfg_write),.bank_routes(ui_in[1:0]),
      .host_req(host_req),.host_we(host_we),.host_addr(host_addr),.host_wdata(host_wdata),
      .host_ready(host_ready),.host_rvalid(host_rvalid),.host_rdata(host_rdata),
      .tx_start(start),.tx_base({2'b00,source_addr}),.tx_length(tx_length),
      .rx_base({2'b00,dest_addr}),.rx_capacity(rx_capacity),
      .pin_in({uio_in[0],uio_in[0]}),.pin_out(pins),.pin_oe(pin_oe),.configured(configured),
      .tx_done(tx_done),.tx_error(tx_error),.rx_overflow(rx_overflow),.tx_active(tx_active),
      .rx_received(rx_received),.rx_written(rx_written),.tx_queued(tx_queued),.rx_queued(rx_queued),
      .spi_start(start),.spi_source_addr({2'b00,source_addr}),.spi_dest_addr({2'b00,dest_addr}),
      .spi_done(spi_done),.spi_error(spi_error),.spi_active(spi_active));
  wire finish=uart_mode ? tx_done : spi_done;
  wire [7:0] status={rx_overflow,tx_error,tx_active,spi_error,spi_active,3'b000};
  assign uo_out=(uio_in[4:2]==3'd7 && !sync2) ? {7'b0,pins[2]} :
                (uio_in[4:2]==3'd4 && !sync2) ? status : read_data;
  assign uio_out={finish,pins[0],pins[1],5'b0};
  assign uio_oe={arm && configured,pin_oe[0],pin_oe[1],5'b0};
  always @(posedge clk) begin
    if(!reset_n) begin
      sync1<=0;sync2<=0;strobe_prev<=0;arm<=0;cfg_mode<=0;uart_mode<=0;
      host_req<=0;host_we<=0;host_addr<=0;host_wdata<=0;read_data<=0;
      source_addr<=0;dest_addr<=0;cfg_low<=0;tx_length<=0;rx_capacity<=0;start<=0;
    end else begin
      sync1<=uio_in[1];sync2<=sync1;strobe_prev<=sync2;start<=0;
      if(host_req && host_ready) host_req<=0;
      if(host_rvalid) read_data<=host_rdata;
      if(image_write) begin
        if(host_addr[4:0]==26) uart_mode<=image_word[0];
        if(host_addr[4:0]==27) tx_length<=image_word[10:0];
        if(host_addr[4:0]==28) rx_capacity<=image_word[10:0];
      end
      if(command && !host_req) begin
        case(uio_in[4:2])
          0:host_addr[7:0]<=ui_in;
          1:host_addr[9:8]<=ui_in[1:0];
          2:begin host_wdata<=ui_in;host_we<=1;host_req<=1;end
          3:begin host_we<=0;host_req<=1;end
          4:begin arm<=ui_in[2];if(!arm) cfg_mode<=ui_in[3];end
          5:if(arm && !(uart_mode ? tx_active : spi_active)) start<=1;
          6:if(cfg_mode && !arm) cfg_low<=ui_in;else if(!arm) source_addr<=ui_in;
          7:if(!cfg_mode && !arm) dest_addr<=ui_in;
          default:begin end
        endcase
      end
    end
  end
  wire unused=&{1'b0,rx_received,rx_written,tx_queued,rx_queued,uio_in[7:5]};
endmodule
`default_nettype wire
