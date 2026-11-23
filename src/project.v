/* SPDX-License-Identifier: Apache-2.0 */
`default_nettype none
// Two-SRAM physical experiment. This is a test vehicle, not the old chip ABI.
// ui_in carries a command byte. Hold it and uio_in[4:2] stable while
// strobing uio_in[1] high for at least four clocks, then low for four.
// Opcodes: 0 address low, 1 address high, 2 write, 3 read, 4 route/arm,
// 5 start, 6 source address low, 7 destination address low. In configuration
// mode, 6 sets a config-word low byte and 7 writes its high byte at host_addr.
// Route/arm byte: bits [1:0] bank routes, bit 2 arm, bit 3 config mode.
// Write routes and config while disarmed, then issue a separate arm command.
module tt_um_protocol_emulator (
    input wire [7:0] ui_in, output wire [7:0] uo_out,
    input wire [7:0] uio_in, output wire [7:0] uio_out,
    output wire [7:0] uio_oe, input wire ena, input wire clk, input wire rst_n
);
  wire reset_n = rst_n && ena;
  reg sync1, sync2, strobe_prev;
  wire command = sync2 && !strobe_prev;
  reg arm, host_req, host_we, cfg_mode;
  reg [9:0] host_addr;
  reg [7:0] host_wdata, read_data, source_addr, dest_addr, cfg_low;
  reg start;
  wire host_ready, host_rvalid, cs, sck, mosi, done, error, active;
  wire [3:0] io_enable;
  wire [7:0] host_rdata;
  wire cfg_write = command && uio_in[4:2] == 3'd4 && !arm && !ui_in[2];
  wire image_write = command && uio_in[4:2] == 3'd7 && !arm && cfg_mode;
  memory_spi_fabric #(.USE_MACRO(1)) fabric (
      .clk(clk), .rst_n(reset_n), .arm(arm), .cfg_we(image_write), .cfg_addr(host_addr[4:0]),
      .cfg_data({ui_in,cfg_low}), .bank_cfg_we(cfg_write), .bank_routes(ui_in[1:0]),
      .host_req(host_req), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
      .host_ready(host_ready), .host_rvalid(host_rvalid), .host_rdata(host_rdata),
      .trigger(start),
      .source_addr({2'b00,source_addr}), .dest_addr({2'b00,dest_addr}),
      .miso(uio_in[0]), .cs(cs), .sck(sck), .mosi(mosi), .oe(io_enable[2:0]),
      .done(done), .error(error), .active(active)
  );
  assign io_enable[3]=io_enable[0];
  // Idle opcode 7 exposes CS on uo[0]; opcode 3 exposes host read data.
  assign uo_out = (uio_in[4:2]==3'd7 && !sync2) ? {7'b0,cs} : read_data;
  assign uio_out = {done, mosi, sck, 5'b0};
  assign uio_oe = {io_enable[3],io_enable[2],io_enable[1],5'b0};
  always @(posedge clk) begin
    if (!reset_n) begin
      sync1<=0; sync2<=0; strobe_prev<=0; arm<=0; cfg_mode<=0; cfg_low<=0;
      host_req<=0; host_we<=0; host_addr<=0; host_wdata<=0; read_data<=0;
      source_addr<=0; dest_addr<=0; start<=0;
    end else begin
      sync1<=uio_in[1]; sync2<=sync1; strobe_prev<=sync2; start<=0;
      if (host_req && host_ready) host_req<=0;
      if (host_rvalid) read_data<=host_rdata;
      if (command && !host_req) begin
        case (uio_in[4:2])
          3'd0: host_addr[7:0]<=ui_in;
          3'd1: host_addr[9:8]<=ui_in[1:0];
          3'd2: begin host_wdata<=ui_in; host_we<=1; host_req<=1; end
          3'd3: begin host_we<=0; host_req<=1; end
          3'd4: begin arm<=ui_in[2]; if (!arm) cfg_mode<=ui_in[3]; end
          3'd5: if (arm && !active) start<=1;
          3'd6: if (cfg_mode && !arm) cfg_low<=ui_in; else source_addr<=ui_in;
          3'd7: if (!cfg_mode) dest_addr<=ui_in;
          default: begin end
        endcase
      end
    end
  end
  // These signals are intentionally unobserved in this physical test vehicle.
  wire unused = &{1'b0, error, uio_in[7:5], ui_in[7:2]};
endmodule
`default_nettype wire
