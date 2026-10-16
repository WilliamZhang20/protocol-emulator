`default_nettype none

// PX8 transaction controller. Bit timing lives in the spatial fabric; this
// small CPU only configures tiles, sequences framing decisions, and joins on
// fabric events. Every instruction is one byte {op[3:0], n[3:0]}; larger
// operands are built with PFIX prefixes (Transputer style):
//   opnd = O | n, and every non-prefix instruction clears O afterwards.
//
//   0 PFIX  O = (O | n) << 4        8 WCF   cfg[opnd] = A
//   1 LDC   A = opnd                9 RD    A = rd[opnd]
//   2 SETP  P = opnd (data pointer) A WEV   wait for line opnd (pulse lines
//                                           are sticky and consumed)
//   3 XRC   A = A ^ opnd            B FIRE  pulse line 2 + opnd[0]
//   4 J     pc = opnd               C PIN   CPU pin n[2:0] := n[3]
//   5 JZ    if A == 0: pc = opnd    D DLY   stall opnd extra cycles
//   6 DJNZ  C -= 1; if C != 0: pc   E OPR   misc (below)
//   7 SETC  C = opnd                F ANDC  A = A & opnd
//
//   OPR: 0 NOP, 1 HALT, 2 PULL (A = TX byte, stalls), 3 PUSH (RX = A[7:0],
//        stalls), 4 CLREV (clear sticky events), 5 A = C, 6 C = A,
//        7 TXP (TX FIFO = A[7:0], stalls while full),
//        8 LDM (A = SRAM[P], P += 1: data stored after the program),
//        9 CFG (block config load: C words, each the three SRAM bytes
//          {addr, data[7:0], data[15:8]} at P; then P += 3C, C = 0 and
//          A = the last word)
//        PULL, PUSH and TXP use FIFO channel opnd[4] (PFIX 1 for channel 1).
//
// The controller only reacts to the fabric; bit timing never depends on
// it. So waits see registered inputs: a WEV on a level line (32-63) sees
// the level one cycle late and never retires in its first execute cycle.
//
// Timing: every instruction takes 2 cycles (fetch + execute) plus stalls;
// LDM takes 3, a level WEV at least 3, and CFG 1 + 3 per word.
module px8_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    output wire [9:0]  instruction_address,
    output wire        instruction_read,
    input  wire [7:0]  instruction_data,
    output wire        cfg_we,
    output wire [7:0]  cfg_addr,
    output wire [15:0] cfg_data,
    output wire [3:0]  rd_addr,
    input  wire [15:0] rd_data,
    input  wire        event_ready,
    output wire        event_consume,
    output wire [5:0]  event_index,
    output wire        clear_events,
    output wire [1:0]  fire,
    output wire        pin_we,
    output wire [2:0]  pin_index,
    output wire        pin_value,
    output wire        channel,
    output wire        tx_request,
    input  wire        tx_grant,
    input  wire [7:0]  tx_data,
    output wire        tx_push,
    input  wire        tx_space,
    output wire        rx_request,
    input  wire        rx_grant,
    output wire [7:0]  rx_data,
    output wire        halted
);
  localparam ST_FETCH = 3'd0;
  localparam ST_EXEC  = 3'd1;
  localparam ST_HALT  = 3'd2;
  localparam ST_LOAD  = 3'd3;
  localparam ST_CFG   = 3'd4;

  localparam OP_PFIX = 4'h0;
  localparam OP_LDC  = 4'h1;
  localparam OP_SETP = 4'h2;
  localparam OP_XRC  = 4'h3;
  localparam OP_J    = 4'h4;
  localparam OP_JZ   = 4'h5;
  localparam OP_DJNZ = 4'h6;
  localparam OP_SETC = 4'h7;
  localparam OP_WCF  = 4'h8;
  localparam OP_RD   = 4'h9;
  localparam OP_WEV  = 4'ha;
  localparam OP_FIRE = 4'hb;
  localparam OP_PIN  = 4'hc;
  localparam OP_DLY  = 4'hd;
  localparam OP_OPR  = 4'he;
  localparam OP_ANDC = 4'hf;

  reg [2:0]  state;
  reg [9:0]  pc;
  reg [9:0]  ptr;       // P: LDM and CFG data pointer
  reg [11:0] oreg;      // O[15:4]; a prefix always leaves O[3:0] zero
  reg [15:0] acc;
  reg [15:0] cnt;
  reg [15:0] delay;
  reg        waiting;   // the executing instruction has already stalled
  reg [7:0]  blk_addr;  // CFG: address byte of the word being loaded
  reg [1:0]  blk_byte;  // CFG: which byte of {addr, lo, hi} arrives now

  wire [3:0]  op   = instruction_data[7:4];
  wire [3:0]  n    = instruction_data[3:0];
  wire [15:0] opnd = {oreg, n};
  wire        exec = enable && state == ST_EXEC;

  wire is_pull = op == OP_OPR && opnd[3:0] == 4'd2;
  wire is_push = op == OP_OPR && opnd[3:0] == 4'd3;
  wire is_txp  = op == OP_OPR && opnd[3:0] == 4'd7;
  wire is_ldm  = op == OP_OPR && opnd[3:0] == 4'd8;
  wire is_cfg  = op == OP_OPR && opnd[3:0] == 4'd9;

  // CFG streams one SRAM byte per cycle: each read issued at P returns
  // the next cycle, and every third byte completes a config write.
  wire block      = state == ST_CFG;
  wire block_word = block && blk_byte == 2'd2;
  wire block_last = block_word && cnt == 16'd1;

  // An executing instruction either retires this cycle or stalls in EXEC.
  reg retire;
  always @(*) begin
    case (op)
      OP_WEV:  retire = event_ready && (waiting || !opnd[5]);
      OP_DLY:  retire = waiting ? delay == 16'd1 : opnd == 16'd0;
      OP_OPR:  retire = is_pull ? tx_grant : is_push ? rx_grant :
                        is_txp ? tx_space : 1'b1;
      default: retire = 1'b1;
    endcase
  end

  wire [15:0] cnt_dec = cnt - 16'd1;
  reg [9:0] next_pc;
  always @(*) begin
    next_pc = pc + 10'd1;
    case (op)
      OP_J:    next_pc = opnd[9:0];
      OP_JZ:   if (acc == 16'd0) next_pc = opnd[9:0];
      OP_DJNZ: if (cnt_dec != 16'd0) next_pc = opnd[9:0];
      default: begin end
    endcase
  end

  // LDM and CFG read SRAM at P while executing; LDM's byte arrives in
  // ST_LOAD, CFG's bytes in ST_CFG.
  wire data_read = exec && (is_ldm || (is_cfg && cnt != 16'd0));
  assign instruction_address = (data_read || block) ? ptr : pc;
  assign instruction_read    = enable && (state == ST_FETCH || data_read ||
                                          (block && !block_last));
  assign cfg_we        = (exec && op == OP_WCF) || block_word;
  assign cfg_addr      = block ? blk_addr : opnd[7:0];
  assign cfg_data      = block ? {instruction_data, acc[7:0]} : acc;
  assign rd_addr       = opnd[3:0];
  assign event_consume = exec && op == OP_WEV && retire;
  assign event_index   = opnd[5:0];
  assign clear_events  = exec && op == OP_OPR && opnd[3:0] == 4'd4;
  assign fire          = (exec && op == OP_FIRE) ?
                         (opnd[0] ? 2'b10 : 2'b01) : 2'b00;
  assign pin_we        = exec && op == OP_PIN;
  assign pin_index     = n[2:0];
  assign pin_value     = n[3];
  assign channel       = opnd[4];
  assign tx_request    = exec && is_pull;
  assign rx_request    = exec && is_push;
  assign rx_data       = acc[7:0];
  assign tx_push       = exec && is_txp && tx_space;
  assign halted        = state == ST_HALT;

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      state    <= ST_FETCH;
      pc       <= 10'd0;
      ptr      <= 10'd0;
      oreg     <= 12'd0;
      acc      <= 16'd0;
      cnt      <= 16'd0;
      delay    <= 16'd0;
      waiting  <= 1'b0;
      blk_addr <= 8'd0;
      blk_byte <= 2'd0;
    end else begin
      case (state)
        ST_FETCH: state <= ST_EXEC;
        ST_EXEC: begin
          waiting <= !retire;
          if (op == OP_DLY && !retire)
            delay <= waiting ? delay - 16'd1 : opnd;
          if (retire) begin
            pc       <= next_pc;
            oreg     <= op == OP_PFIX ? opnd[11:0] : 12'd0;
            state    <= is_ldm ? ST_LOAD : ST_FETCH;
            if (data_read)
              ptr <= ptr + 10'd1;
            case (op)
              OP_LDC:  acc <= opnd;
              OP_SETP: ptr <= opnd[9:0];
              OP_XRC:  acc <= acc ^ opnd;
              OP_ANDC: acc <= acc & opnd;
              OP_RD:   acc <= rd_data;
              OP_SETC: cnt <= opnd;
              OP_DJNZ: cnt <= cnt_dec;
              OP_OPR: begin
                case (opnd[3:0])
                  4'd1: state <= ST_HALT;
                  4'd2: acc <= {8'd0, tx_data};
                  4'd5: acc <= cnt;
                  4'd6: cnt <= acc;
                  4'd9: if (cnt != 16'd0) begin
                    state    <= ST_CFG;
                    blk_byte <= 2'd0;
                  end
                  default: begin end
                endcase
              end
              default: begin end
            endcase
          end
        end
        ST_LOAD: begin
          acc   <= {8'd0, instruction_data};
          state <= ST_FETCH;
        end
        ST_CFG: begin
          blk_byte <= block_word ? 2'd0 : blk_byte + 2'd1;
          if (!block_last)
            ptr <= ptr + 10'd1;
          case (blk_byte)
            2'd0: blk_addr <= instruction_data;
            2'd1: acc[7:0] <= instruction_data;
            default: begin
              acc <= cfg_data;
              cnt <= cnt_dec;
              if (block_last)
                state <= ST_FETCH;
            end
          endcase
        end
        default: begin end
      endcase
    end
  end
endmodule

`default_nettype wire
