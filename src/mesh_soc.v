`default_nettype none
// The mesh with real SRAM streams (FABRIC_REORG.md step 4, roadmap item 1):
// the word network's reader and writer ports are the existing stream
// reader and writer (grid_stream_tiles.v) on the existing two-bank stream
// memory (grid_stream_memory.v; host, reader and writer round-robin per
// single-port bank). Nothing in the mesh changes.
//
// Host port (the bench plays the host):
// - memory: host_req/we/addr/wdata -> host_ready, host_rvalid/rdata; address
//   bit 10 selects the bank (the memory's host route, rewritten with a
//   one-clock disarm when it changes; the request waits until the route
//   matches, so it never reaches the previous bank);
// - streams: rd_start with rd_base/rd_length sends that region through the
//   reader (rd_active, rd_done); wr_start with wr_base/wr_length opens a
//   receive region for the writer (wr_active, wr_done when full), and
//   wr_count says how many bytes it has written;
// - packets: each received byte tagged eop (the word network's bit 8, from
//   the receive shifter) queues a descriptor {err (bit 9 of any byte of the
//   packet), end: the bytes accepted into the region after it}; pk_count
//   descriptors (at most 4; a fifth is dropped and sets pk_overflow), the
//   oldest at pk_end/pk_err, pk_pop removes it. A region start clears them.
//   The reader tags the last byte of each region it sends eop (bit 8): a
//   region is one packet out.
// The reader and writer pick their bank from their own address bit 10.
// host_ev, seen/seen_clear and param_* pass straight to the mesh (its
// host-sequenced steps). mesh_hold keeps the mesh alone in reset (the chip
// writes its configuration meanwhile; releasing it loads the tiles).
module mesh_soc #(parameter ROWS=3, COLS=5, WORD_PORT=6,
  parameter [2*ROWS*COLS-1:0] KINDS=30'd287029521,
  parameter [ROWS*COLS-1:0] CTX4=15'd10570,
  parameter [ROWS*COLS-1:0] CNT=0,
  parameter [ROWS*COLS-1:0] LOGIC=0,
  parameter DSLOTS=0,          // ctx_switch static/dynamic split (mesh.v)
  parameter [3:0] CTX_TRACKS=4'b1111, // with DSLOTS=0: tracks held per context (mesh.v)
  parameter REG=1,             // registered-routing study point (mesh.v; 1 is the mesh)
  parameter ACTOR=0,           // logic cells with the control-actor mode (mesh.v)
  parameter USE_MACRO=0,       // 1: the SRAM macros (chip); 0: the behavioural banks
  parameter CELL_BITS=512, WNET_BITS=128,
  parameter CFG_BITS=ROWS*COLS*CELL_BITS+WNET_BITS)(
  input wire clk, rst_n, run_req,
  input wire mesh_hold,        // the mesh (not the memory or streams) held in reset
  input wire [3:0] host_ev,
  output wire [4*ROWS*COLS-1:0] seen, input wire seen_clear,
  input wire param_we, input wire [3:0] param_cell, input wire [2:0] param_addr, input wire [15:0] param_data,
  input wire [CFG_BITS-1:0] cfg,
  input wire [7:0] pins,
  output wire [7:0] pad_oe, pad_out,
  output wire ready,
  input wire host_req, host_we, input wire [10:0] host_addr, input wire [7:0] host_wdata,
  output wire host_ready, host_rvalid, output wire [7:0] host_rdata,
  input wire rd_start, input wire [10:0] rd_base, rd_length, output wire rd_active, rd_done,
  input wire wr_start, input wire [10:0] wr_base, wr_length, output wire wr_active, wr_done,
  output wire [10:0] wr_count,
  output wire [2:0] pk_count, output wire [10:0] pk_end, output wire pk_err, output reg pk_overflow,
  input wire pk_pop,
  output wire [ROWS*COLS-1:0] host_valid, output wire [8*ROWS*COLS-1:0] host_byte);
  // Mesh <-> word-network endpoints.
  wire [15:0] m_rd_data, m_wr_data; wire m_rd_valid, m_rd_ready, m_wr_valid, m_wr_ready;
  mesh #(.ROWS(ROWS),.COLS(COLS),.WORD_PORT(WORD_PORT),.KINDS(KINDS),.CTX4(CTX4),.CNT(CNT),.LOGIC(LOGIC),.DSLOTS(DSLOTS),.CTX_TRACKS(CTX_TRACKS),.REG(REG),.ACTOR(ACTOR)) fabric(
    clk,rst_n && !mesh_hold,run_req,host_ev,seen,seen_clear,param_we,param_cell,param_addr,param_data,cfg,pins,pad_oe,pad_out,ready,m_rd_data,m_rd_valid,m_rd_ready,
    m_wr_data,m_wr_valid,m_wr_ready,host_valid,host_byte);

  // Host bank route: rewritten while the memory is disarmed for one clock.
  reg host_bank, mem_off;
  always @(posedge clk)
    if(!rst_n) begin host_bank<=0; mem_off<=1; end
    else if(host_addr[10]!=host_bank && host_req) begin host_bank<=host_addr[10]; mem_off<=1; end
    else mem_off<=0;
  wire mem_en=!mem_off;
  // The reader and writer stay enabled across a host route change: their
  // enable is a reset, so only the memory (whose route register can be
  // written only while it is disarmed) sees the one-clock disarm; a stream
  // request during it simply waits for its grant.
  wire stream_en=1'b1;

  wire [2:0] m_ready, m_rvalid; wire [23:0] m_rdata;
  wire rq, wq, r_err, w_err; wire [10:0] raddr, waddr; wire [7:0] wdata, rdq_data;
  wire [1:0] r_queued, r_out, w_queued; wire r_valid;
  grid_stream_reader #(.DEPTH(2)) reader(clk,rst_n,stream_en,rd_start,rd_base,rd_length,
    rq,m_ready[1],raddr,m_rvalid[1],m_rdata[15:8],r_valid,m_rd_ready && r_valid,rdq_data,
    rd_active,rd_done,r_err,r_queued,r_out);
  // Packets out: the last byte of a reader region goes onto the word
  // network tagged eop (bit 8), so a transmitter whose burst ends on a
  // packet (fabric_shifter burst [6]) ends it there. One region is one
  // packet.
  reg [10:0] rd_left;
  always @(posedge clk)
    if(!rst_n) rd_left<=0;
    else if(rd_start) rd_left<=rd_length;
    else if(m_rd_valid && m_rd_ready && rd_left!=0) rd_left<=rd_left-1;
  assign m_rd_valid=r_valid; assign m_rd_data={7'd0,rd_left==11'd1,rdq_data};
  grid_stream_writer #(.DEPTH(2)) writer(clk,rst_n,stream_en,wr_start,wr_base,wr_length,
    m_wr_valid,m_wr_ready,m_wr_data[7:0],wq,m_ready[2],waddr,wdata,wr_active,wr_done,w_err,w_queued);
  grid_stream_memory #(.USE_MACRO(USE_MACRO)) memory(clk,rst_n,mem_en,mem_off,{host_bank,host_bank,host_bank},
    {waddr[10],raddr[10]},{wq,rq,host_req && mem_en && host_addr[10]==host_bank},{1'b1,1'b0,host_we},
    {waddr[9:0],raddr[9:0],host_addr[9:0]},{wdata,8'b0,host_wdata},m_ready,m_rvalid,m_rdata);
  assign host_ready=m_ready[0]; assign host_rvalid=m_rvalid[0]; assign host_rdata=m_rdata[7:0];
  // Bytes written so far into the open receive region.
  reg [10:0] written;
  always @(posedge clk)
    if(!rst_n || wr_start) written<=0;
    else if(wq && m_ready[2]) written<=written+1;
  assign wr_count=written;
  // Packet descriptors.
  reg [10:0] accepted; reg pk_bad;
  reg [11:0] pk_q[0:3]; reg [1:0] pk_rd, pk_wr; reg [2:0] pk_n;
  wire acc = m_wr_valid && m_wr_ready;
  wire pk_in = acc && m_wr_data[8] && pk_n != 3'd4;
  wire pk_out = pk_pop && pk_n != 3'd0;
  always @(posedge clk)
    if(!rst_n || wr_start) begin
      accepted<=0; pk_bad<=0; pk_rd<=0; pk_wr<=0; pk_n<=0; pk_overflow<=0;
    end else begin
      if(acc) begin
        accepted<=accepted+1;
        pk_bad<=m_wr_data[8] ? 1'b0 : pk_bad || m_wr_data[9];
      end
      if(pk_in) begin pk_q[pk_wr]<={pk_bad || m_wr_data[9], accepted+11'd1}; pk_wr<=pk_wr+1; end
      if(acc && m_wr_data[8] && pk_n == 3'd4 && !pk_out) pk_overflow<=1;
      if(pk_out) pk_rd<=pk_rd+1;
      pk_n<=pk_n+{2'b0,pk_in}-{2'b0,pk_out};
    end
  assign pk_count=pk_n;
  // The head reads 0 while the queue is empty (its entries are not reset).
  assign pk_end=pk_n!=3'd0 ? pk_q[pk_rd][10:0] : 11'd0; assign pk_err=pk_n!=3'd0 && pk_q[pk_rd][11];
endmodule
`default_nettype wire
