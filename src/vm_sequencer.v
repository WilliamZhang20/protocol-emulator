`default_nettype none

// Control CPU: fetches bytecode from the program SRAM, steps the
// fetch/operand/execute state machine, and emits one-cycle strobes to the
// shared resources. See docs/architecture.md for the instruction set.
//
// Every SRAM access takes a REQUEST cycle followed by a WAIT cycle in which
// the byte is on instruction_data. An instruction byte therefore costs
// FETCH_REQUEST + FETCH_WAIT + EXECUTE (3 cycles) and each operand byte costs
// 2 more. This timing is frozen: characterized programs depend on it.
module vm_sequencer (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire [7:0] instruction_data,
    input  wire       tx_empty,
    input  wire       rx_full,
    input  wire       action_busy,
    input  wire       action_control_ready,
    input  wire       action_start_ready,
    input  wire       cpu_pin_conflict,
    input  wire       crc_busy,
    input  wire       event_wait_matched,
    input  wire       timer_expired,
    input  wire       pin_wait_satisfied,
    input  wire       alu_zero,
    input  wire       djnz_nonzero,
    input  wire       time_satisfied,
    output reg  [3:0] state,
    output reg  [9:0] program_counter,
    output reg  [7:0] instruction,
    output reg  [7:0] operand_low,
    output reg  [7:0] operand_mid,
    output reg  [7:0] operand_ext,
    output reg        operand_ext_valid,
    output reg        halted,
    output wire       instruction_read,
    output wire [3:0] opcode,
    output wire [3:0] immediate,
    output wire       execute_gpio_write,
    output wire       execute_oe_write,
    output wire       execute_shift_out,
    output wire       execute_map,
    output wire       execute_tx_load,
    output wire       execute_shift_in,
    output wire       execute_shift_clear,
    output wire       timer_load,
    output wire       timer_async,
    output wire       timer_count_enable,
    output wire       arm_edges,
    output wire       wait_event_clear,
    output wire       tx_pop,
    output wire       rx_push,
    output wire       crc_setup,
    output wire       crc_feed,
    output wire       crc_finalize,
    output wire       crc_push_lo,
    output wire       crc_push_hi,
    output wire       alu_set,
    output wire       alu_mov,
    output wire       alu_op,
    output wire       djnz_strobe,
    output wire       time_rd,
    output wire       time_wait_active,
    output wire       ev_stamp,
    output wire       ev_detail,
    output wire       sideset_apply,
    output wire [2:0] sideset_pin,
    output wire       sideset_val,
    output wire       crc_setup32,
    output wire       crc_push_b2,
    output wire       crc_push_b3,
    output wire       action_wr_lo,
    output wire       action_wr_hi,
    output wire       action_wr_lane_lo,
    output wire       action_wr_lane_hi,
    output wire       action_start,
    output wire       action_load_shift,
    output wire       action_load_shift_hi,
    output wire       action_load_tx,
    output wire       action_read_result,
    output wire       action_push_result,
    output wire       wait_region_active,
    output wire       wait_region_clear
);
  // ---------------------------------------------------------------------------
  // States
  // ---------------------------------------------------------------------------
  localparam STATE_IDLE                 = 4'd0;
  localparam STATE_FETCH_REQUEST        = 4'd1;
  localparam STATE_FETCH_WAIT           = 4'd2;
  localparam STATE_EXECUTE              = 4'd3;
  localparam STATE_OPERAND_LOW_REQUEST  = 4'd4;
  localparam STATE_OPERAND_LOW_WAIT     = 4'd5;
  localparam STATE_OPERAND_HIGH_REQUEST = 4'd6;
  localparam STATE_OPERAND_HIGH_WAIT    = 4'd7;
  localparam STATE_TIMER_WAIT           = 4'd8;
  localparam STATE_HALTED               = 4'd9;
  localparam STATE_OPERAND_EXT_REQUEST  = 4'd10;
  localparam STATE_OPERAND_EXT_WAIT     = 4'd11;
  localparam STATE_EVENT_WAIT           = 4'd12;
  localparam STATE_TIME_WAIT            = 4'd13;
  localparam STATE_REGION_WAIT          = 4'd14;

  // ---------------------------------------------------------------------------
  // Opcodes (instruction[7:4])
  // ---------------------------------------------------------------------------
  localparam OP_SYSTEM     = 4'h0;  // 00 NOP, 01 HALT, 02-0F SIDESET
  localparam OP_WAIT16     = 4'h1;
  localparam OP_PIN_WRITE  = 4'h2;
  localparam OP_OE_WRITE   = 4'h3;
  localparam OP_TX_LOAD    = 4'h4;
  localparam OP_SHIFT_OUT  = 4'h5;
  localparam OP_SHIFT_IN   = 4'h6;
  localparam OP_RX_PUSH    = 4'h7;
  localparam OP_BRANCH     = 4'h8;
  localparam OP_WAIT_PIN   = 4'h9;
  localparam OP_GROUP_A    = 4'ha;  // CRC, ALU, and time sub-ops
  localparam OP_MAP        = 4'hb;
  localparam OP_GROUP_C    = 4'hc;  // C8 lane TX load; others are NOPs
  localparam OP_WAIT_EVENT = 4'hd;
  localparam OP_GROUP_E    = 4'he;  // timer, CRC-32, and action sub-ops
  localparam OP_ARM_EDGE   = 4'hf;

  // Group A sub-ops (immediate). 6-9 are NOPs.
  localparam A_SHIFT_CLEAR  = 4'h0;
  localparam A_CRC_SETUP    = 4'h1;
  localparam A_CRC_FEED     = 4'h2;
  localparam A_CRC_FINALIZE = 4'h3;
  localparam A_CRC_PUSH_LO  = 4'h4;
  localparam A_CRC_PUSH_HI  = 4'h5;
  localparam A_SET          = 4'ha;
  localparam A_MOV          = 4'hb;
  localparam A_ALU          = 4'hc;
  localparam A_GET_TIME     = 4'hd;
  localparam A_WAIT_UNTIL   = 4'he;
  localparam A_EVENT_STAMP  = 4'hf;

  // Group E sub-ops (immediate).
  localparam E_START_TIMER    = 4'h0;
  localparam E_CRC32_SETUP    = 4'h1;
  localparam E_CRC_PUSH_B2    = 4'h2;
  localparam E_CRC_PUSH_B3    = 4'h3;
  localparam E_RUN_REGION     = 4'h4;
  localparam E_RUN_REGION_N   = 4'h5;
  localparam E_WAIT_REGION    = 4'h6;
  localparam E_READ_RESULT    = 4'h7;
  localparam E_WR_LO          = 4'h8;
  localparam E_WR_HI          = 4'h9;
  localparam E_LOAD_SHIFT_LO  = 4'ha;
  localparam E_WR_BUNDLE_LO   = 4'hb;
  localparam E_WR_BUNDLE_HI   = 4'hc;
  localparam E_EVENT_DETAIL   = 4'hd;
  localparam E_LOAD_SHIFT_HI  = 4'he;
  localparam E_PUSH_RESULT    = 4'hf;

  localparam C_LANE_TX_LOAD = 4'h8;

  // ---------------------------------------------------------------------------
  // Decode
  // ---------------------------------------------------------------------------
  assign opcode = instruction[7:4];
  assign immediate = instruction[3:0];

  wire group_a = opcode == OP_GROUP_A;
  wire group_e = opcode == OP_GROUP_E;

  wire is_crc_setup   = group_a && immediate == A_CRC_SETUP;
  wire is_crc_feed    = group_a && immediate == A_CRC_FEED;
  wire is_crc_fin     = group_a && immediate == A_CRC_FINALIZE;
  wire is_crc_lo      = group_a && immediate == A_CRC_PUSH_LO;
  wire is_crc_hi      = group_a && immediate == A_CRC_PUSH_HI;
  wire is_alu_set     = group_a && immediate == A_SET;
  wire is_alu_mov     = group_a && immediate == A_MOV;
  wire is_alu_op      = group_a && immediate == A_ALU;
  wire is_get_time    = group_a && immediate == A_GET_TIME;
  wire is_wait_until  = group_a && immediate == A_WAIT_UNTIL;
  wire is_ev_stamp    = group_a && immediate == A_EVENT_STAMP;

  wire is_crc32_setup       = group_e && immediate == E_CRC32_SETUP;
  wire is_crc32_b2          = group_e && immediate == E_CRC_PUSH_B2;
  wire is_crc32_b3          = group_e && immediate == E_CRC_PUSH_B3;
  wire is_run_region        = group_e && immediate == E_RUN_REGION;
  wire is_run_region_n      = group_e && immediate == E_RUN_REGION_N;
  wire is_read_result       = group_e && immediate == E_READ_RESULT;
  wire is_action_wr_lo      = group_e && immediate == E_WR_LO;
  wire is_action_wr_hi      = group_e && immediate == E_WR_HI;
  wire is_action_load_sh    = group_e && immediate == E_LOAD_SHIFT_LO;
  wire is_action_wr_lane_lo = group_e && immediate == E_WR_BUNDLE_LO;
  wire is_action_wr_lane_hi = group_e && immediate == E_WR_BUNDLE_HI;
  wire is_ev_detail         = group_e && immediate == E_EVENT_DETAIL;
  wire is_action_load_hi    = group_e && immediate == E_LOAD_SHIFT_HI;
  wire is_action_push       = group_e && immediate == E_PUSH_RESULT;
  wire is_action_tx_load = opcode == OP_GROUP_C && immediate == C_LANE_TX_LOAD;
  wire is_action_table_write = is_action_wr_lo || is_action_wr_hi ||
                               is_action_wr_lane_lo || is_action_wr_lane_hi;

  // 00 is NOP and 01 is HALT; 02-0F latch a side-set {val, pin} that is
  // applied atomically with the next instruction's EXECUTE.
  wire is_sideset = opcode == OP_SYSTEM && immediate != 4'h0 &&
                    immediate != 4'h1;

  // 80 JMP, 81 JZ, 82 JNZ, 88-8F DJNZ Rn. Other 8x immediates also jump.
  wire is_jz   = opcode == OP_BRANCH && immediate == 4'h1;
  wire is_jnz  = opcode == OP_BRANCH && immediate == 4'h2;
  wire is_djnz = opcode == OP_BRANCH && immediate[3];
  wire branch_taken = (is_jz && alu_zero) ||
      (is_jnz && !alu_zero) || (is_djnz && djnz_nonzero) ||
      (opcode == OP_BRANCH && !is_jz && !is_jnz && !is_djnz);
  wire [9:0] jump_target = {instruction_data[1:0], operand_low};

  // CPU pushes to the RX FIFO wait for space and for every lane to be idle,
  // since a running lane may own the port.
  wire cpu_rx_ready = !rx_full && !action_busy;

  wire in_execute    = state == STATE_EXECUTE;
  wire in_low_wait   = state == STATE_OPERAND_LOW_WAIT;
  wire in_high_wait  = state == STATE_OPERAND_HIGH_WAIT;

  // READ_RESULT and PUSH_RESULT accept on OPERAND_LOW_WAIT but act one cycle
  // later from the latched operand, keeping the SRAM output off the lane
  // result and RX FIFO paths. That cycle is always FETCH_REQUEST.
  reg read_result_pending;
  reg push_result_pending;

  // Side-set latched by a prefix, applied at the next EXECUTE.
  reg [2:0] sideset_pin_r;
  reg sideset_val_r;
  reg sideset_pending;

  // CRC feed/finalize pulse once, then the sequencer waits for crc_busy to
  // fall before moving on.
  reg crc_issued;

  // ---------------------------------------------------------------------------
  // Resource strobes
  // ---------------------------------------------------------------------------
  assign instruction_read =
      state == STATE_FETCH_REQUEST ||
      state == STATE_OPERAND_LOW_REQUEST ||
      state == STATE_OPERAND_HIGH_REQUEST ||
      state == STATE_OPERAND_EXT_REQUEST;

  assign sideset_apply = in_execute && sideset_pending;
  assign sideset_pin = sideset_pin_r;
  assign sideset_val = sideset_val_r;

  // GPIO, CPU shifter, and pin map.
  assign execute_gpio_write = in_execute && opcode == OP_PIN_WRITE;
  assign execute_oe_write = in_execute && opcode == OP_OE_WRITE;
  assign execute_shift_out = in_execute && opcode == OP_SHIFT_OUT;
  assign execute_shift_in = in_execute && opcode == OP_SHIFT_IN;
  assign execute_shift_clear =
      in_execute && group_a && immediate == A_SHIFT_CLEAR;
  assign execute_tx_load =
      in_execute && opcode == OP_TX_LOAD && !tx_empty && !action_busy;
  assign execute_map = in_low_wait && opcode == OP_MAP && !action_busy;

  // Timer and events. The timer decode checks only the opcode, so the
  // two-operand group E action ops (E5, E8, E9, EB, EC) also load and start
  // the asynchronous timer on their second operand.
  assign timer_load = in_high_wait &&
                      (opcode == OP_WAIT16 || opcode == OP_GROUP_E);
  assign timer_async = in_high_wait && opcode == OP_GROUP_E;
  assign timer_count_enable = state == STATE_TIMER_WAIT;
  assign arm_edges = in_high_wait && opcode == OP_ARM_EDGE;
  assign wait_event_clear = state == STATE_EVENT_WAIT && event_wait_matched;
  assign ev_stamp = in_execute && is_ev_stamp && cpu_rx_ready;
  assign ev_detail = in_execute && is_ev_detail && cpu_rx_ready;

  // CRC. CRC_SETUP fires on the first EXT_WAIT cycle, when poly_hi is on
  // instruction_data.
  assign crc_setup = state == STATE_OPERAND_EXT_WAIT && is_crc_setup &&
                     !operand_ext_valid && !crc_busy;
  assign crc_feed = in_low_wait && is_crc_feed && !crc_issued && !crc_busy;
  assign crc_finalize = in_execute && is_crc_fin && !crc_issued && !crc_busy;
  assign crc_setup32 = in_execute && is_crc32_setup && !crc_busy;
  assign crc_push_lo = in_execute && is_crc_lo && cpu_rx_ready;
  assign crc_push_hi = in_execute && is_crc_hi && cpu_rx_ready;
  assign crc_push_b2 = in_execute && is_crc32_b2 && cpu_rx_ready;
  assign crc_push_b3 = in_execute && is_crc32_b3 && cpu_rx_ready;

  // Register file and time.
  assign alu_mov = in_low_wait && is_alu_mov;
  assign alu_set = in_high_wait && is_alu_set;
  assign alu_op = in_high_wait && is_alu_op;
  assign djnz_strobe = in_high_wait && is_djnz;
  assign time_rd = in_low_wait && is_get_time;
  assign time_wait_active = state == STATE_TIME_WAIT;

  // Action engine. Table writes fire when their data byte arrives; E4 starts
  // on its single operand and E5 on its count operand.
  assign action_wr_lo = in_high_wait && is_action_wr_lo && action_control_ready;
  assign action_wr_hi = in_high_wait && is_action_wr_hi && action_control_ready;
  assign action_wr_lane_lo =
      in_high_wait && is_action_wr_lane_lo && action_control_ready;
  assign action_wr_lane_hi =
      in_high_wait && is_action_wr_lane_hi && action_control_ready;
  assign action_start =
      ((in_low_wait && is_run_region) || (in_high_wait && is_run_region_n)) &&
      action_start_ready;
  assign action_load_shift =
      in_low_wait && is_action_load_sh && action_control_ready;
  assign action_load_shift_hi =
      in_low_wait && is_action_load_hi && action_control_ready;
  assign action_load_tx =
      in_low_wait && is_action_tx_load && !tx_empty && action_control_ready;
  assign action_read_result = read_result_pending;
  assign action_push_result = push_result_pending;
  assign wait_region_active = state == STATE_REGION_WAIT;
  assign wait_region_clear = state == STATE_REGION_WAIT && event_wait_matched;

  // FIFO ports.
  assign tx_pop = execute_tx_load || action_load_tx;
  assign rx_push =
      (in_execute && opcode == OP_RX_PUSH && cpu_rx_ready) ||
      crc_push_lo || crc_push_hi || ev_stamp ||
      crc_push_b2 || crc_push_b3 || ev_detail || action_push_result;

  // ---------------------------------------------------------------------------
  // State machine
  // ---------------------------------------------------------------------------

  // Consume the current byte and move to `next`.
  task advance;
    input [3:0] next;
    begin
      program_counter <= program_counter + 1'b1;
      state <= next;
    end
  endtask

  // Pulse a CRC operation once, then advance when the engine is idle again.
  task crc_handshake;
    begin
      if (!crc_issued && !crc_busy)
        crc_issued <= 1'b1;
      else if (crc_issued && !crc_busy) begin
        crc_issued <= 1'b0;
        advance(STATE_FETCH_REQUEST);
      end
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= STATE_IDLE;
      program_counter <= 10'b0;
      instruction <= 8'b0;
      operand_low <= 8'b0;
      operand_mid <= 8'b0;
      operand_ext <= 8'b0;
      operand_ext_valid <= 1'b0;
      halted <= 1'b0;
      sideset_pin_r <= 3'b0;
      sideset_val_r <= 1'b0;
      sideset_pending <= 1'b0;
      crc_issued <= 1'b0;
      read_result_pending <= 1'b0;
      push_result_pending <= 1'b0;
    end else if (!enable) begin
      state <= STATE_IDLE;
      program_counter <= 10'b0;
      halted <= 1'b0;
      sideset_pending <= 1'b0;
      crc_issued <= 1'b0;
      read_result_pending <= 1'b0;
      push_result_pending <= 1'b0;
    end else begin
      read_result_pending <= in_low_wait && is_read_result &&
                             action_control_ready;
      push_result_pending <= in_low_wait && is_action_push && !rx_full &&
                             action_control_ready;

      case (state)
        STATE_IDLE: begin
          program_counter <= 10'b0;
          halted <= 1'b0;
          state <= STATE_FETCH_REQUEST;
        end

        STATE_FETCH_REQUEST: state <= STATE_FETCH_WAIT;

        STATE_FETCH_WAIT: begin
          instruction <= instruction_data;
          state <= STATE_EXECUTE;
        end

        // Execute single-byte instructions, or decide which operands to
        // fetch. A pin claimed by a running region holds the CPU here.
        STATE_EXECUTE: if (!cpu_pin_conflict) begin
          // A pending side-set applies on this cycle, then clears unless
          // this instruction is itself a prefix (prefixes chain).
          if (sideset_pending && !is_sideset)
            sideset_pending <= 1'b0;

          case (opcode)
            OP_SYSTEM: begin
              if (immediate == 4'h1) begin
                // HALT waits for running regions to finish.
                if (!action_busy) begin
                  halted <= 1'b1;
                  state <= STATE_HALTED;
                end
              end else begin
                if (is_sideset) begin
                  sideset_pin_r <= immediate[2:0];
                  sideset_val_r <= immediate[3];
                  sideset_pending <= 1'b1;
                end
                advance(STATE_FETCH_REQUEST);
              end
            end

            OP_WAIT16, OP_BRANCH, OP_ARM_EDGE, OP_MAP, OP_WAIT_EVENT:
              advance(STATE_OPERAND_LOW_REQUEST);

            OP_GROUP_C:
              advance(is_action_tx_load ? STATE_OPERAND_LOW_REQUEST :
                                          STATE_FETCH_REQUEST);

            OP_GROUP_E: begin
              case (immediate)
                E_CRC32_SETUP:
                  if (!crc_busy) advance(STATE_FETCH_REQUEST);
                E_CRC_PUSH_B2, E_CRC_PUSH_B3, E_EVENT_DETAIL:
                  if (cpu_rx_ready) advance(STATE_FETCH_REQUEST);
                // WAIT_REGION advances the PC when the join completes.
                E_WAIT_REGION: state <= STATE_REGION_WAIT;
                E_START_TIMER, E_RUN_REGION, E_RUN_REGION_N, E_READ_RESULT,
                E_WR_LO, E_WR_HI, E_WR_BUNDLE_LO, E_WR_BUNDLE_HI,
                E_LOAD_SHIFT_LO, E_LOAD_SHIFT_HI, E_PUSH_RESULT:
                  advance(STATE_OPERAND_LOW_REQUEST);
              endcase
            end

            OP_GROUP_A: begin
              case (immediate)
                A_CRC_FINALIZE: crc_handshake;
                A_CRC_PUSH_LO, A_CRC_PUSH_HI, A_EVENT_STAMP:
                  if (cpu_rx_ready) advance(STATE_FETCH_REQUEST);
                A_CRC_SETUP, A_CRC_FEED, A_SET, A_MOV, A_ALU, A_GET_TIME,
                A_WAIT_UNTIL:
                  advance(STATE_OPERAND_LOW_REQUEST);
                // SHIFT_CLEAR and the undefined sub-ops.
                default: advance(STATE_FETCH_REQUEST);
              endcase
            end

            OP_TX_LOAD:
              if (!tx_empty && !action_busy) advance(STATE_FETCH_REQUEST);

            OP_RX_PUSH:
              if (cpu_rx_ready) advance(STATE_FETCH_REQUEST);

            OP_WAIT_PIN:
              if (pin_wait_satisfied) advance(STATE_FETCH_REQUEST);

            // PIN_WRITE, OE_WRITE, SHIFT_OUT, SHIFT_IN.
            default: advance(STATE_FETCH_REQUEST);
          endcase
        end

        STATE_OPERAND_LOW_REQUEST: state <= STATE_OPERAND_LOW_WAIT;

        // First operand is on instruction_data. One-operand instructions
        // finish here; the rest fetch a second operand.
        STATE_OPERAND_LOW_WAIT: begin
          operand_low <= instruction_data;
          if (is_action_tx_load) begin
            if (!tx_empty && action_control_ready)
              advance(STATE_FETCH_REQUEST);
          end else if (is_crc_feed) begin
            crc_handshake;
          end else if (opcode == OP_MAP || is_alu_mov || is_get_time) begin
            // MAP does not wait for a busy lane; execute_map is suppressed.
            advance(STATE_FETCH_REQUEST);
          end else if (is_read_result || is_action_load_sh ||
                       is_action_load_hi) begin
            if (action_control_ready)
              advance(STATE_FETCH_REQUEST);
          end else if (is_action_push) begin
            if (!rx_full && action_control_ready)
              advance(STATE_FETCH_REQUEST);
          end else if (is_run_region) begin
            if (action_start_ready)
              advance(STATE_FETCH_REQUEST);
          end else if (is_wait_until) begin
            advance(STATE_TIME_WAIT);
          end else if (opcode == OP_WAIT_EVENT) begin
            advance(STATE_EVENT_WAIT);
          end else begin
            advance(STATE_OPERAND_HIGH_REQUEST);
          end
        end

        STATE_OPERAND_HIGH_REQUEST: state <= STATE_OPERAND_HIGH_WAIT;

        // Second operand is on instruction_data.
        STATE_OPERAND_HIGH_WAIT: begin
          if (opcode == OP_WAIT16) begin
            advance(STATE_TIMER_WAIT);
          end else if (is_action_table_write) begin
            if (action_control_ready)
              advance(STATE_FETCH_REQUEST);
          end else if (is_run_region_n) begin
            if (action_start_ready)
              advance(STATE_FETCH_REQUEST);
          end else if (opcode == OP_GROUP_E || opcode == OP_ARM_EDGE) begin
            // START_TIMER, ARM_EDGE.
            advance(STATE_FETCH_REQUEST);
          end else if (is_crc_setup) begin
            operand_mid <= instruction_data;
            advance(STATE_OPERAND_EXT_REQUEST);
          end else if (is_alu_set || is_alu_op) begin
            operand_mid <= instruction_data;
            advance(STATE_FETCH_REQUEST);
          end else if (opcode == OP_BRANCH) begin
            if (branch_taken)
              program_counter <= jump_target;
            else
              program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end else begin
            // Not reached: every instruction routed here is handled above.
            program_counter <= jump_target;
            state <= STATE_FETCH_REQUEST;
          end
        end

        // Third operand (CRC_SETUP poly_hi). It is captured once; a busy
        // CRC engine holds the sequencer here.
        STATE_OPERAND_EXT_REQUEST: begin
          operand_ext_valid <= 1'b0;
          state <= STATE_OPERAND_EXT_WAIT;
        end

        STATE_OPERAND_EXT_WAIT: begin
          if (!is_crc_setup || !crc_busy) begin
            if (!operand_ext_valid) begin
              operand_ext <= instruction_data;
              operand_ext_valid <= 1'b1;
            end
            advance(STATE_FETCH_REQUEST);
          end
        end

        // Blocking waits. The PC already points past the instruction,
        // except for WAIT_REGION, which has no operand.
        STATE_EVENT_WAIT:
          if (event_wait_matched) state <= STATE_FETCH_REQUEST;

        STATE_REGION_WAIT:
          if (event_wait_matched) advance(STATE_FETCH_REQUEST);

        STATE_TIME_WAIT:
          if (time_satisfied) state <= STATE_FETCH_REQUEST;

        STATE_TIMER_WAIT:
          if (timer_expired) state <= STATE_FETCH_REQUEST;

        STATE_HALTED: begin
          halted <= 1'b1;
          state <= STATE_HALTED;
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
