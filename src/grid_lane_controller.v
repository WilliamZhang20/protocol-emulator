`default_nettype none
// Lane controller: decides, never times a bit. Tiles (timers, shifters,
// coders) produce every edge whose cycle position matters; this controller
// waits for events, compares received values, moves stream bytes, sets
// action levels and starts tiles. Responses that must land inside a window
// (an ACK slot, the next SPI byte) are bounded by its fixed decision time.
//
// The program is copied from SRAM into a local 64-instruction buffer when
// the lane starts, so execution never waits on memory: one instruction per
// clock, except waits, which retire on their condition. Instructions are 16
// bits, little-endian in SRAM, {op[3:0], arg[11:0]}:
//
//   0 SYS  arg[3:0]: 0 NOP, 1 HALT (done), 2 FAIL (done with error),
//          3 CLEAR events, 4 SHIFT (tx word = A, start the shifter),
//          5 PULL (A = next stream byte; waits), 6 PUSH (stream <- A[7:0];
//          waits), 7 C = A[7:0], 8 A = C, 9 SHL (A <<= 1), 10 SHR (A >>= 1);
//          other values fail
//   1 WAIT e = arg[3:0]: e 0-7 a latched pulse event (consumed), e 8-15 a
//          live level (waits while low)
//   2 ACT  actions = arg[3:0] (levels, held until the next ACT)
//   3 FIRE pulse the start line
//   4 LDI  A = arg            7 XOR A ^= arg        A JZ   if A == 0: pc = arg
//   5 RD   A = readback[arg[3:0]]  8 ADD A += arg   B JNZ  if A != 0: pc = arg
//   6 AND  A &= arg           9 J    pc = arg       C LOOP C -= 1; if C != 0: pc = arg
//   D SETC C = arg[7:0]
//   E WCFG configuration word arg[7:0] = A; only lane-owned words
//          OWN_FIRST..OWN_LAST (the grid lane: the five alternate-context
//          words 112-116; a lane core: its own words); any other address fails, and
//          so does a value the fabric refuses (cfg_ok low: the word would
//          break the rules static configuration is checked against)
//   F WANY m = arg[7:0]: wait until any latched pulse event in m is set;
//          A = the set bits of m, which are consumed. arg[11:8] != 0 or an
//          empty mask fails
// A is 16 bits (immediates zero-extend); C is 8 bits. Jumps and execution
// beyond the loaded program fail. Abort fails. Everything fails closed.
module grid_lane_controller #(parameter ABITS=6,parameter [7:0] OWN_FIRST=8'd112,parameter [7:0] OWN_LAST=8'd116)(
  input wire clk,rst_n,enable,start,abort,
  input wire [9:0] prog_base,input wire [5:0] prog_last,
  // Program load: borrows a memory client like grid_page_loader.
  output wire mem_req,input wire mem_ready,output wire [9:0] mem_addr,
  input wire mem_rvalid,input wire [7:0] mem_rdata,
  output wire owns_port,output reg resp_pending,
  input wire [7:0] events,input wire [7:0] levels,
  input wire [255:0] readback,
  input wire [3:0] idle_actions,
  output wire [3:0] actions,output wire fire,output reg [15:0] tx_word,output wire tx_load,
  input wire rd_valid,input wire [7:0] rd_data,output wire rd_consume,output wire rd_want,
  output wire wr_valid,output wire [7:0] wr_data,input wire wr_ready,
  output wire cfg_we,output wire [7:0] cfg_addr,output wire [15:0] cfg_data,input wire cfg_ok,
  output reg active,output reg loading,output reg done,output reg error,
  output reg [5:0] pc,output reg [15:0] acc,output reg [7:0] count
`ifdef FORMAL
  // Internal state for the reference-model proof (formal/lane_controller).
  ,output wire [7:0] dbg_latched,output wire [3:0] dbg_act,output wire [7:0] dbg_sent,dbg_got,dbg_low,
  output wire dbg_shift_fire,output wire [(16<<ABITS)-1:0] dbg_prog
`endif
  );
  // Program buffer: 2**ABITS instructions (64 on chip; the formal harness
  // uses 8 to keep the proof small).
  reg [15:0] prog [0:(1<<ABITS)-1];
  reg [7:0] latched;
  reg [3:0] act;
  reg [7:0] sent,got;
  reg shift_fire;
  reg [7:0] low;
  wire [7:0] bytes={1'b0,prog_last,1'b1}+8'd1;   // 2 * (prog_last + 1)
  // ---- program load
  wire issue=mem_req && mem_ready;
  assign mem_req=loading && sent!=bytes;
  assign mem_addr=prog_base+{2'b0,sent};
  assign owns_port=loading;
  // ---- execution
  // Disarming (enable low) silences every output in the same clock.
  wire running=enable && active && !loading;
  // Outputs decode only a loaded instruction: past the end the lane fails.
  wire exec=running && pc<=prog_last;
  wire [15:0] ir=prog[pc[ABITS-1:0]];
  wire [3:0] op=ir[15:12];
  wire [11:0] arg=ir[11:0];
  wire [3:0] sys=arg[3:0];
  wire [3:0] sel=arg[3:0];
  wire wait_ok=sel[3] ? levels[sel[2:0]] : (latched[sel[2:0]] || events[sel[2:0]]);
  wire target_ok=arg[11:6]==0 && arg[5:0]<=prog_last;
  wire sys_ok=sys<=4'd10;
  // In OWN_FIRST..OWN_LAST: one unsigned compare of the wrapped offset.
  localparam [7:0] OWN_SPAN=OWN_LAST-OWN_FIRST;
  wire [7:0] own_offset=arg[7:0]-OWN_FIRST;
  wire owned=own_offset<=OWN_SPAN && arg[11:8]==0;
  wire do_wait=exec && op==4'h1;
  wire [7:0] seen=latched | events;
  wire [7:0] any_hit=seen & arg[7:0];
  wire any_bad=arg[11:8]!=0 || arg[7:0]==0;
  wire do_any=exec && op==4'hF && !any_bad;
  wire do_pull=exec && op==4'h0 && sys==4'd5;
  wire do_push=exec && op==4'h0 && sys==4'd6;
  // An instruction retires this clock unless it waits.
  wire retire=running && !(do_wait && !wait_ok) && !(do_any && any_hit==0) && !(do_pull && !rd_valid) && !(do_push && !wr_ready);
  assign rd_consume=do_pull && rd_valid;
  assign rd_want=do_pull;   // the fabric fails a PULL that can never be served
  assign wr_valid=do_push;
  assign wr_data=acc[7:0];
  // SHIFT loads the word this clock and starts the shifter the next, so the
  // shifter latches the new word.
  assign fire=(exec && op==4'h3) || shift_fire;
  assign tx_load=exec && op==4'h0 && sys==4'd4;
  assign cfg_we=exec && op==4'hE && owned && cfg_ok;
  assign cfg_addr=arg[7:0];
  assign cfg_data=acc;
  assign actions=(enable && active) ? act : idle_actions;
  // Readback is a word array indexed by sel; part-select bases are
  // constants only (see grid_page_loader).
  wire [15:0] rb_word[0:15];
  genvar ri;
  generate for(ri=0;ri<16;ri=ri+1) begin: readback_words
    assign rb_word[ri]=readback[ri*16+:16];
  end endgenerate
  wire [15:0] rb=rb_word[sel];
  wire [5:0] next_pc=pc+1'b1;
  always @(posedge clk) begin
    done<=0;
    resp_pending<=rst_n && issue;
    shift_fire<=rst_n && enable && tx_load;
    if(!rst_n || !enable) begin
      active<=0;loading<=0;error<=0;pc<=0;acc<=0;count<=0;latched<=0;act<=0;sent<=0;got<=0;
      if(!rst_n) tx_word<=0;
    end else begin
      // Pulse events latch until a WAIT consumes them or CLEAR runs.
      latched<=latched | events;
      if(active && abort) begin active<=0;loading<=0;done<=1;error<=1;end
      else if(start && !active) begin
        active<=1;loading<=1;error<=0;pc<=0;acc<=0;count<=0;latched<=0;act<=idle_actions;sent<=0;got<=0;
      end else if(loading) begin
        if(issue) sent<=sent+1'b1;
        if(resp_pending && mem_rvalid) begin
          got<=got+1'b1;
          if(!got[0]) low<=mem_rdata;
          else prog[got[ABITS:1]]<={mem_rdata,low};
          if(got==bytes-1'b1) loading<=0;
        end
      end else if(running && pc>prog_last) begin
        active<=0;done<=1;error<=1;
      end else if(retire) begin
        pc<=next_pc;
        case(op)
          4'h0: case(sys)
            4'd1: begin active<=0;done<=1;end
            4'd2: begin active<=0;done<=1;error<=1;end
            4'd3: latched<=events;
            4'd4: tx_word<=acc;
            4'd5: acc<={8'b0,rd_data};
            4'd7: count<=acc[7:0];
            4'd8: acc<={8'b0,count};
            4'd9: acc<={acc[14:0],1'b0};
            4'd10: acc<={1'b0,acc[15:1]};
            4'd0,4'd6: ;
            default: begin active<=0;done<=1;error<=1;end
          endcase
          4'h1: if(!sel[3]) latched[sel[2:0]]<=1'b0;
          4'h2: act<=arg[3:0];
          4'h3: ;   // FIRE: the start pulse is combinational
          4'h4: acc<={4'b0,arg};
          4'h5: acc<=rb;
          4'h6: acc<=acc & {4'b0,arg};
          4'h7: acc<=acc ^ {4'b0,arg};
          4'h8: acc<=acc + {4'b0,arg};
          4'h9,4'hA,4'hB,4'hC: begin
            if(op==4'hC) count<=count-1'b1;
            if(op==4'h9 || (op==4'hA && acc==0) || (op==4'hB && acc!=0) || (op==4'hC && count!=8'd1)) begin
              if(target_ok) pc<=arg[5:0];
              else begin active<=0;done<=1;error<=1;end
            end
          end
          4'hD: count<=arg[7:0];
          4'hE: if(!owned || !cfg_ok) begin active<=0;done<=1;error<=1;end
          4'hF: if(any_bad) begin active<=0;done<=1;error<=1;end
                else begin acc<={8'b0,any_hit};latched<=seen & ~arg[7:0];end
        endcase
      end
    end
  end
  wire unused=&{1'b0,sys_ok,next_pc};
`ifdef FORMAL
  assign dbg_latched=latched;assign dbg_act=act;assign dbg_sent=sent;assign dbg_got=got;assign dbg_low=low;
  assign dbg_shift_fire=shift_fire;
  genvar gi;
  generate for(gi=0;gi<(1<<ABITS);gi=gi+1) begin: dbg_words
    assign dbg_prog[gi*16+:16]=prog[gi];
  end endgenerate
`endif
endmodule
`default_nettype wire
