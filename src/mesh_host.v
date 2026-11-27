`default_nettype none
// Host interface of the mesh chip (FABRIC_REORG.md step 6.1). The link is
// the chip's 12 host pins: `data` (stable while `strobe` is high), `op`, and
// `strobe`, synchronized here; a command is a strobe rise.
//
// Commands (op):
//   0  address[7:0]  <= data
//   1  address[15:8] <= data
//   2  write data at address; address + 1
//   3  read at address into read_data (the chip's uo pins); address + 1
//   4  host events: data[3:0] for one clock (the mesh's host_ev)
//   5  clear the sticky flags (seen)
//   6, 7  nothing
// A command that arrives while an SRAM access or a configuration write is
// in flight waits for it (one is held); the host leaves a few clocks between strobes anyway.
//
// Address map:
//   0x0000-0x07FF  SRAM (bit 10 selects the bank), through mesh_soc's host port
//   0x1000-0x13FF  configuration bytes (mesh_cfg: byte b = vector bits
//                  [8b, 8b+8)); written only while the mesh is held; read 0
//   0x2000-       control registers:
//     00 CTRL      [0] run [1] hold (reset 1); writing [2]=1 clears the
//                  configuration. The mesh runs while run && !hold.
//     01 STATUS    [7] ready (configuration loaded) [6] reader active
//                  [5] reader done (since its start) [4] writer active
//                  [3] writer done (since its start)
//     02/03 reader base [7:0]/[10:8]  04/05 reader length; write 06: start
//     08/09 writer base               0A/0B writer length; write 0C: start
//     0D/0E bytes written so far [7:0]/[10:8] (read)
//     10-17 sticky flags seen[8k +: 8] (read), 4 per cell
//     18 parameter cell, 19 parameter register, 1A/1B parameter value;
//        writing 1B writes the parameter (mesh param port) a clock later
//     1C write: host events data[3:0]   1D write: clear the sticky flags
module mesh_host #(parameter CFG_ABITS=10, SEEN_BITS=60)(
  input wire clk, rst_n,
  input wire [7:0] data, input wire [2:0] op, input wire strobe,
  output reg [7:0] read_data,
  // SRAM, through mesh_soc's host port (grant host_ready is combinational)
  output reg mem_req, mem_we, output reg [10:0] mem_addr, output reg [7:0] mem_wdata,
  input wire mem_ready, mem_rvalid, input wire [7:0] mem_rdata,
  // configuration storage
  output wire cfg_we, output wire [CFG_ABITS-1:0] cfg_addr, output wire [7:0] cfg_data, output wire cfg_clear,
  input wire cfg_busy,               // a configuration write still settling (mesh_cfg)
  // mesh and streams
  output wire mesh_hold, run_req, input wire ready,
  output wire rd_start, output reg [10:0] rd_base, rd_length, input wire rd_active, rd_done,
  output wire wr_start, output reg [10:0] wr_base, wr_length, input wire wr_active, wr_done,
  input wire [10:0] wr_count,
  output wire [3:0] host_ev, input wire [SEEN_BITS-1:0] seen, output wire seen_clear,
  output reg param_we, output reg [3:0] param_cell, output reg [2:0] param_addr, output reg [15:0] param_data);

  reg s1, s2, s_prev;
  wire command = s2 && !s_prev;
  // One command held while an SRAM access is in flight.
  reg pend; reg [2:0] p_op; reg [7:0] p_data;
  reg mem_wait;                         // a read granted, its data next clock
  wire busy = mem_req || mem_wait || cfg_busy;
  wire go = !busy && (pend || command);
  wire [2:0] c_op = pend ? p_op : op;
  wire [7:0] c_data = pend ? p_data : data;

  reg [15:0] addr;
  reg run, hold, rd_done_s, wr_done_s;
  wire [3:0] region = addr[15:12];
  wire [7:0] reg_a = addr[7:0];
  wire wr = go && c_op == 3'd2, rd = go && c_op == 3'd3;
  wire ctl_wr = wr && region == 4'd2;

  assign cfg_we = wr && region == 4'd1 && hold;
  assign cfg_addr = addr[CFG_ABITS-1:0];
  assign cfg_data = c_data;
  assign cfg_clear = ctl_wr && reg_a == 8'h00 && c_data[2];
  assign mesh_hold = hold;
  assign run_req = run && !hold;
  assign rd_start = ctl_wr && reg_a == 8'h06;
  assign wr_start = ctl_wr && reg_a == 8'h0C;
  assign host_ev = (go && c_op == 3'd4) ? c_data[3:0] : (ctl_wr && reg_a == 8'h1C) ? c_data[3:0] : 4'd0;
  assign seen_clear = (go && c_op == 3'd5) || (ctl_wr && reg_a == 8'h1D);

  wire [63:0] seen64 = {{(64-SEEN_BITS){1'b0}}, seen};
  reg [7:0] ctl_q;
  always @* begin
    case(reg_a)
      8'h00: ctl_q = {6'b0, hold, run};
      8'h01: ctl_q = {ready, rd_active, rd_done_s, wr_active, wr_done_s, 3'b0};
      8'h02: ctl_q = rd_base[7:0];   8'h03: ctl_q = {5'b0, rd_base[10:8]};
      8'h04: ctl_q = rd_length[7:0]; 8'h05: ctl_q = {5'b0, rd_length[10:8]};
      8'h08: ctl_q = wr_base[7:0];   8'h09: ctl_q = {5'b0, wr_base[10:8]};
      8'h0A: ctl_q = wr_length[7:0]; 8'h0B: ctl_q = {5'b0, wr_length[10:8]};
      8'h0D: ctl_q = wr_count[7:0];  8'h0E: ctl_q = {5'b0, wr_count[10:8]};
      8'h10: ctl_q = seen64[7:0];    8'h11: ctl_q = seen64[15:8];
      8'h12: ctl_q = seen64[23:16];  8'h13: ctl_q = seen64[31:24];
      8'h14: ctl_q = seen64[39:32];  8'h15: ctl_q = seen64[47:40];
      8'h16: ctl_q = seen64[55:48];  8'h17: ctl_q = seen64[63:56];
      8'h18: ctl_q = {4'b0, param_cell}; 8'h19: ctl_q = {5'b0, param_addr};
      8'h1A: ctl_q = param_data[7:0];    8'h1B: ctl_q = param_data[15:8];
      default: ctl_q = 8'd0;
    endcase
  end

  always @(posedge clk) begin
    if(!rst_n) begin
      s1 <= 0; s2 <= 0; s_prev <= 0; pend <= 0; p_op <= 0; p_data <= 0;
      mem_req <= 0; mem_we <= 0; mem_addr <= 0; mem_wdata <= 0; mem_wait <= 0;
      addr <= 0; read_data <= 0; run <= 0; hold <= 1; rd_done_s <= 0; wr_done_s <= 0;
      rd_base <= 0; rd_length <= 0; wr_base <= 0; wr_length <= 0;
      param_cell <= 0; param_addr <= 0; param_data <= 0; param_we <= 0;
    end else begin
      s1 <= strobe; s2 <= s1; s_prev <= s2;
      param_we <= ctl_wr && reg_a == 8'h1B;     // the clock after the value's high byte lands
      // SRAM: the access happens on the clock it is granted; read data
      // follows one clock later.
      if(mem_req && mem_ready) begin mem_req <= 0; mem_wait <= !mem_we; end
      if(mem_wait && mem_rvalid) begin read_data <= mem_rdata; mem_wait <= 0; end
      if(command && busy) begin pend <= 1; p_op <= op; p_data <= data; end
      else if(go) pend <= 0;
      if(rd_done) rd_done_s <= 1;
      if(wr_done) wr_done_s <= 1;
      if(go) begin
        case(c_op)
          3'd0: addr[7:0] <= c_data;
          3'd1: addr[15:8] <= c_data;
          3'd2, 3'd3: begin
            addr <= addr + 16'd1;
            if(region == 4'd0) begin
              mem_req <= 1; mem_we <= c_op == 3'd2; mem_addr <= addr[10:0]; mem_wdata <= c_data;
            end else if(c_op == 3'd3)
              read_data <= region == 4'd2 ? ctl_q : 8'd0;
          end
          default: ;
        endcase
      end
      if(ctl_wr) begin
        case(reg_a)
          8'h00: begin run <= c_data[0]; hold <= c_data[1]; end
          8'h02: rd_base[7:0] <= c_data;   8'h03: rd_base[10:8] <= c_data[2:0];
          8'h04: rd_length[7:0] <= c_data; 8'h05: rd_length[10:8] <= c_data[2:0];
          8'h06: rd_done_s <= 0;
          8'h08: wr_base[7:0] <= c_data;   8'h09: wr_base[10:8] <= c_data[2:0];
          8'h0A: wr_length[7:0] <= c_data; 8'h0B: wr_length[10:8] <= c_data[2:0];
          8'h0C: wr_done_s <= 0;
          8'h18: param_cell <= c_data[3:0]; 8'h19: param_addr <= c_data[2:0];
          8'h1A: param_data[7:0] <= c_data; 8'h1B: param_data[15:8] <= c_data;
          default: ;
        endcase
      end
    end
  end
endmodule
`default_nettype wire
