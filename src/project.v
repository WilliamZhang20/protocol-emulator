/* SPDX-License-Identifier: Apache-2.0 */
`default_nettype none
// The mesh chip (FABRIC_REORG.md step 6): a contexted mesh of coarse tiles
// and logic cells (src/mesh.v) with its SRAM streams on the two SRAM macros
// (mesh_soc), its configuration storage (mesh_cfg) and the host interface
// (mesh_host). The mesh is the compiler contract mesh_3x5_L3S (FABRIC_REORG.md
// step 8 result, area-reduced by O3): 3 rows x 5 columns, row-major
//   timer logic io    logic timer
//   shifter crc* shifter crc io        (* word port)
//   timer counter logic counter timer
// with contexts on the four cells programs switch (io (0,2), crc* (1,1),
// shifter (1,2), io (1,4)) and only tracks 0 and 2 held per context.
//
// Pins:
//   ui[7:0]   host data (stable while the strobe is high)
//   uio[1]    host strobe (a command on each rise)
//   uio[4:2]  host command (mesh_host.v)
//   uo[7:0]   the last read byte
//   uio[0], uio[5], uio[6], uio[7]  protocol pads 0-3 (mesh pads; each
//             driven only while the mesh drives it: open drain or push-pull
//             as configured). The mesh's pads 4-7 are not bonded.
module tt_um_protocol_emulator (
    input wire [7:0] ui_in, output wire [7:0] uo_out,
    input wire [7:0] uio_in, output wire [7:0] uio_out,
    output wire [7:0] uio_oe, input wire ena, input wire clk, input wire rst_n
);
  localparam ROWS=3, COLS=5, N=ROWS*COLS, WORD_PORT=6;
  localparam [2*N-1:0] KINDS=30'd357808453;
  localparam [N-1:0] CTX4=15'd708, CNT=15'd10240, LOGIC=15'd4106;
  // Static/dynamic split (FABRIC_REORG.md O3): no indexed slots; tracks 0
  // and 2 (one per turn class) and the sinks held per context, the other
  // tracks once (4'b1111 would hold every track per context).
  localparam DSLOTS=0;
  localparam [3:0] CTX_TRACKS=4'b0101;
  localparam CFG_BITS=N*512+128;
  wire reset_n = rst_n && ena;

  wire mem_req, mem_we, mem_ready, mem_rvalid; wire [10:0] mem_addr; wire [7:0] mem_wdata, mem_rdata;
  wire cfg_we, cfg_clear, cfg_busy; wire [9:0] cfg_addr; wire [7:0] cfg_data; wire [CFG_BITS-1:0] cfg;
  wire mesh_hold, run_req, ready;
  wire rd_start, rd_active, rd_done, wr_start, wr_active, wr_done; wire [10:0] rd_base, rd_length, wr_base, wr_length, wr_count;
  wire [2:0] pk_count; wire [10:0] pk_end; wire pk_err, pk_overflow, pk_pop;
  wire [3:0] host_ev; wire [4*N-1:0] seen; wire seen_clear;
  wire param_we; wire [3:0] param_cell; wire [2:0] param_addr; wire [15:0] param_data;

  mesh_host #(.CFG_ABITS(10), .SEEN_BITS(4*N)) host(
    .clk(clk), .rst_n(reset_n), .data(ui_in), .op(uio_in[4:2]), .strobe(uio_in[1]), .read_data(uo_out),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
    .mem_ready(mem_ready), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data), .cfg_clear(cfg_clear), .cfg_busy(cfg_busy),
    .mesh_hold(mesh_hold), .run_req(run_req), .ready(ready),
    .rd_start(rd_start), .rd_base(rd_base), .rd_length(rd_length), .rd_active(rd_active), .rd_done(rd_done),
    .wr_start(wr_start), .wr_base(wr_base), .wr_length(wr_length), .wr_active(wr_active), .wr_done(wr_done),
    .wr_count(wr_count), .pk_count(pk_count), .pk_end(pk_end), .pk_err(pk_err), .pk_overflow(pk_overflow),
    .pk_pop(pk_pop), .host_ev(host_ev), .seen(seen), .seen_clear(seen_clear),
    .param_we(param_we), .param_cell(param_cell), .param_addr(param_addr), .param_data(param_data));

  // CFG_LATCH: the configuration store's storage (mesh_cfg LATCH).
  localparam CFG_LATCH=1;
  mesh_cfg #(.ROWS(ROWS), .COLS(COLS), .KINDS(KINDS), .CTX4(CTX4), .CNT(CNT), .LOGIC(LOGIC), .DSLOTS(DSLOTS), .CTX_TRACKS(CTX_TRACKS), .LATCH(CFG_LATCH)) store(
    clk, reset_n, cfg_clear, cfg_we, cfg_addr, cfg_data, cfg_busy, cfg);

  // Pads 0-3 on uio 0, 5, 6, 7; unbonded pads read high (idle).
  wire [7:0] pad_oe, pad_out;
  wire [7:0] pins = {4'b1111, uio_in[7], uio_in[6], uio_in[5], uio_in[0]};
  wire [N-1:0] host_valid; wire [8*N-1:0] host_byte;
  mesh_soc #(.ROWS(ROWS), .COLS(COLS), .WORD_PORT(WORD_PORT), .KINDS(KINDS), .CTX4(CTX4), .CNT(CNT), .LOGIC(LOGIC), .DSLOTS(DSLOTS), .CTX_TRACKS(CTX_TRACKS), .USE_MACRO(1)) fabric(
    .clk(clk), .rst_n(reset_n), .run_req(run_req), .mesh_hold(mesh_hold), .host_ev(host_ev),
    .seen(seen), .seen_clear(seen_clear),
    .param_we(param_we), .param_cell(param_cell), .param_addr(param_addr), .param_data(param_data),
    .cfg(cfg), .pins(pins), .pad_oe(pad_oe), .pad_out(pad_out), .ready(ready),
    .host_req(mem_req), .host_we(mem_we), .host_addr(mem_addr), .host_wdata(mem_wdata),
    .host_ready(mem_ready), .host_rvalid(mem_rvalid), .host_rdata(mem_rdata),
    .rd_start(rd_start), .rd_base(rd_base), .rd_length(rd_length), .rd_active(rd_active), .rd_done(rd_done),
    .wr_start(wr_start), .wr_base(wr_base), .wr_length(wr_length), .wr_active(wr_active), .wr_done(wr_done),
    .wr_count(wr_count), .pk_count(pk_count), .pk_end(pk_end), .pk_err(pk_err), .pk_overflow(pk_overflow),
    .pk_pop(pk_pop), .host_valid(host_valid), .host_byte(host_byte));

  assign uio_out = {pad_out[3], pad_out[2], pad_out[1], 4'b0, pad_out[0]};
  assign uio_oe  = {pad_oe[3],  pad_oe[2],  pad_oe[1],  4'b0, pad_oe[0]};
  wire unused = &{1'b0, host_valid, host_byte, pad_oe[7:4], pad_out[7:4]};
endmodule
`default_nettype wire
