/* SPDX-License-Identifier: Apache-2.0 */
`default_nettype none
// Two-SRAM physical experiment. This is a test vehicle, not the old chip ABI.
// ui_in carries a command byte. Hold it and uio_in[4:2] stable while
// strobing uio_in[1] high for at least four clocks, then low for four.
// Opcodes: 0 address low, 1 address high, 2 write, 3 read, 4 route/arm,
// 5 start, 6 source address low, 7 destination address low.
// Route/arm byte: bits [1:0] requester bank routes; bit 2 arm. Write routes
// with arm=0 before issuing a separate arm=1 command.
module tt_um_protocol_emulator (
    input wire [7:0] ui_in, output wire [7:0] uo_out,
    input wire [7:0] uio_in, output wire [7:0] uio_out,
    output wire [7:0] uio_oe, input wire ena, input wire clk, input wire rst_n
);
  wire reset_n = rst_n && ena;
  reg sync1, sync2, strobe_prev;
  wire command = sync2 && !strobe_prev;
  reg arm, host_req, host_we;
  reg [1:0] routes;
  reg [9:0] host_addr;
  reg [7:0] host_wdata, read_data, source_addr, dest_addr;
  reg start;
  wire host_ready, host_rvalid, sck, mosi, done, error, waiting, active;
  wire [7:0] host_rdata;
  wire miso;
  wire cfg_write = command && uio_in[4:2] == 3'd4 && !arm && !ui_in[2];
  proto_pin_in input_sync(clk, reset_n, uio_in[0], miso);
  memory_shift_fabric #(.USE_MACRO(1)) fabric (
      .clk(clk), .rst_n(reset_n), .arm(arm), .cfg_we(cfg_write), .cfg_routes(ui_in[1:0]),
      .host_req(host_req), .host_we(host_we), .host_addr(host_addr), .host_wdata(host_wdata),
      .host_ready(host_ready), .host_rvalid(host_rvalid), .host_rdata(host_rdata),
      .start(start), .width(5'd12), .half_period(8'd8),
      .source_addr({2'b00,source_addr}), .dest_addr({2'b00,dest_addr}),
      .serial_in(miso), .sck(sck), .serial_out(mosi), .done(done), .error(error),
      .transfer_waiting(waiting), .transfer_active(active)
  );
  assign uo_out = read_data;
  assign uio_out = {done, mosi, sck, 5'b0};
  assign uio_oe = {3{reset_n && arm}} << 5;
  always @(posedge clk) begin
    if (!reset_n) begin
      sync1<=0; sync2<=0; strobe_prev<=0; arm<=0; routes<=0;
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
          3'd4: begin arm<=ui_in[2]; if (!arm && !ui_in[2]) routes<=ui_in[1:0]; end
          3'd5: if (arm && !active) start<=1;
          3'd6: source_addr<=ui_in;
          3'd7: dest_addr<=ui_in;
          default: begin end
        endcase
      end
    end
  end
  // These signals are intentionally unobserved in this physical test vehicle.
  wire unused = &{1'b0, routes, error, waiting, uio_in[7:5], ui_in[7:2]};
endmodule
`default_nettype wire
