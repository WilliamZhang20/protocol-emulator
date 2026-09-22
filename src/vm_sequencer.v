`default_nettype none

// Instruction fetch/execute FSM plus decoded resource strobes.
// Opcode 0xA immediate sub-ops: shift-clear, CRC, ALU, and time.
// Opcode 0xE immediates 0x4-0xF: action program/run/join/result.
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
  localparam STATE_IDLE = 4'd0;
  localparam STATE_FETCH_REQUEST = 4'd1;
  localparam STATE_FETCH_WAIT = 4'd2;
  localparam STATE_EXECUTE = 4'd3;
  localparam STATE_OPERAND_LOW_REQUEST = 4'd4;
  localparam STATE_OPERAND_LOW_WAIT = 4'd5;
  localparam STATE_OPERAND_HIGH_REQUEST = 4'd6;
  localparam STATE_OPERAND_HIGH_WAIT = 4'd7;
  localparam STATE_TIMER_WAIT = 4'd8;
  localparam STATE_HALTED = 4'd9;
  localparam STATE_OPERAND_EXT_REQUEST = 4'd10;
  localparam STATE_OPERAND_EXT_WAIT = 4'd11;
  localparam STATE_EVENT_WAIT = 4'd12;
  localparam STATE_TIME_WAIT = 4'd13;
  localparam STATE_REGION_WAIT = 4'd14;

  wire decoder_branch;
  wire decoder_delay;
  wire decoder_gpio;
  wire decoder_shift;
  wire decoder_event;

  instruction_decoder decoder (
      .instruction(instruction),
      .opcode(opcode),
      .immediate(immediate),
      .branch_enable(decoder_branch),
      .delay_enable(decoder_delay),
      .gpio_enable(decoder_gpio),
      .shift_enable(decoder_shift),
      .event_enable(decoder_event)
  );

  wire is_crc_setup = opcode == 4'ha && immediate == 4'h1;
  wire is_crc_feed = opcode == 4'ha && immediate == 4'h2;
  wire is_crc_fin = opcode == 4'ha && immediate == 4'h3;
  wire is_crc_lo = opcode == 4'ha && immediate == 4'h4;
  wire is_crc_hi = opcode == 4'ha && immediate == 4'h5;
  // Additive ALU ops (Phase 1): previously-undefined 0xA sub-ops.
  wire is_alu_set = opcode == 4'ha && immediate == 4'ha;
  wire is_alu_mov = opcode == 4'ha && immediate == 4'hb;
  wire is_alu_op = opcode == 4'ha && immediate == 4'hc;
  // Phase 3-4: timestamp + event-stamp ops (previously-undefined 0xA sub-ops).
  wire is_get_time = opcode == 4'ha && immediate == 4'hd;
  wire is_wait_until = opcode == 4'ha && immediate == 4'he;
  wire is_ev_stamp = opcode == 4'ha && immediate == 4'hf;
  // Phase 8: CRC-32 ops in the spare 0xE immediates (0xE0 stays START_TIMER).
  wire is_crc32_setup = opcode == 4'he && immediate == 4'h1;
  wire is_crc32_b2 = opcode == 4'he && immediate == 4'h2;
  wire is_crc32_b3 = opcode == 4'he && immediate == 4'h3;
  wire is_ev_detail = opcode == 4'he && immediate == 4'hd;
  // Phase C/D: action engine — program slots, run/join, read result.
  wire is_run_region = opcode == 4'he && immediate == 4'h4;
  wire is_run_region_n = opcode == 4'he && immediate == 4'h5;
  wire is_wait_region = opcode == 4'he && immediate == 4'h6;
  wire is_read_result = opcode == 4'he && immediate == 4'h7;
  wire is_action_wr_lo = opcode == 4'he && immediate == 4'h8;
  wire is_action_wr_hi = opcode == 4'he && immediate == 4'h9;
  wire is_action_load_sh = opcode == 4'he && immediate == 4'ha;
  wire is_action_wr_lane_lo = opcode == 4'he && immediate == 4'hb;
  wire is_action_wr_lane_hi = opcode == 4'he && immediate == 4'hc;
  wire is_action_load_hi = opcode == 4'he && immediate == 4'he;
  wire is_action_push = opcode == 4'he && immediate == 4'hf;
  wire is_action_tx_load = opcode == 4'hc && immediate == 4'h8;
  // Phase 6: side-set prefix. Opcode 0x0 immediates 0x2-0xF were NOPs;
  // they now latch {pin,val} applied atomically at the next EXECUTE.
  // 0x00 stays NOP, 0x01 stays HALT. Old programs never emit 0x02-0x0F.
  wire is_sideset = opcode == 4'h0 && immediate != 4'h0 && immediate != 4'h1;

  // Side-set latch: pending pin/val applied at the next EXECUTE start.
  reg [2:0] sideset_pin_r;
  reg sideset_val_r;
  reg sideset_pending;
  // One-shot issue flag so CRC feed/finalize are pulsed once,
  // then the sequencer waits for crc_busy to fall.
  reg crc_issued;
  assign sideset_apply = state == STATE_EXECUTE && sideset_pending;
  assign sideset_pin = sideset_pin_r;
  assign sideset_val = sideset_val_r;
  // Conditional branches (Phase 2): 0x80 stays unconditional; immediates
  // select the condition. 0x88-0x8F is DJNZ Rn (reg = imm[2:0]).
  wire is_jmp = opcode == 4'h8 && immediate == 4'h0;
  wire is_jz = opcode == 4'h8 && immediate == 4'h1;
  wire is_jnz = opcode == 4'h8 && immediate == 4'h2;
  wire is_djnz = opcode == 4'h8 && immediate[3];
  wire branch_taken = is_jmp || (is_jz && alu_zero) ||
      (is_jnz && !alu_zero) || (is_djnz && djnz_nonzero) ||
      (opcode == 4'h8 && !is_jz && !is_jnz && !is_djnz);

  assign instruction_read =
      state == STATE_FETCH_REQUEST ||
      state == STATE_OPERAND_LOW_REQUEST ||
      state == STATE_OPERAND_HIGH_REQUEST ||
      state == STATE_OPERAND_EXT_REQUEST;

  assign execute_gpio_write = state == STATE_EXECUTE && opcode == 4'h2;
  assign execute_oe_write = state == STATE_EXECUTE && opcode == 4'h3;
  assign execute_shift_out = state == STATE_EXECUTE && opcode == 4'h5;
  assign execute_map = state == STATE_OPERAND_LOW_WAIT && opcode == 4'hb && !action_busy;
  assign execute_tx_load = state == STATE_EXECUTE && opcode == 4'h4 && !tx_empty && !action_busy;
  assign execute_shift_in = state == STATE_EXECUTE && opcode == 4'h6;
  assign execute_shift_clear =
      state == STATE_EXECUTE && opcode == 4'ha && immediate == 4'h0;

  assign timer_load = state == STATE_OPERAND_HIGH_WAIT &&
                      (opcode == 4'h1 || opcode == 4'he);
  assign timer_async = state == STATE_OPERAND_HIGH_WAIT && opcode == 4'he;
  assign timer_count_enable = state == STATE_TIMER_WAIT;

  assign arm_edges = state == STATE_OPERAND_HIGH_WAIT && opcode == 4'hf;
  assign wait_event_clear = state == STATE_EVENT_WAIT && event_wait_matched;

  // CRC_SETUP fires on first EXT_WAIT cycle (poly_hi on instruction_data).
  assign crc_setup =
      state == STATE_OPERAND_EXT_WAIT && is_crc_setup && !operand_ext_valid &&
      !crc_busy;
  // Bit-serial CRC: pulse feed/finalize only while the engine is idle, then
  // hold the sequencer until busy clears.
  assign crc_feed =
      state == STATE_OPERAND_LOW_WAIT && is_crc_feed && !crc_issued &&
      !crc_busy;
  assign crc_finalize =
      state == STATE_EXECUTE && is_crc_fin && !crc_issued && !crc_busy;
  assign crc_push_lo = state == STATE_EXECUTE && is_crc_lo && !rx_full && !action_busy;
  assign crc_push_hi = state == STATE_EXECUTE && is_crc_hi && !rx_full && !action_busy;

  assign alu_mov = state == STATE_OPERAND_LOW_WAIT && is_alu_mov;
  assign alu_set = state == STATE_OPERAND_HIGH_WAIT && is_alu_set;
  assign alu_op = state == STATE_OPERAND_HIGH_WAIT && is_alu_op;
  assign djnz_strobe = state == STATE_OPERAND_HIGH_WAIT && is_djnz;
  assign time_rd = state == STATE_OPERAND_LOW_WAIT && is_get_time;
  assign time_wait_active = state == STATE_TIME_WAIT;
  assign ev_stamp = state == STATE_EXECUTE && is_ev_stamp && !rx_full && !action_busy;
  assign ev_detail = state == STATE_EXECUTE && is_ev_detail && !rx_full && !action_busy;
  assign crc_setup32 = state == STATE_EXECUTE && is_crc32_setup && !crc_busy;
  assign crc_push_b2 = state == STATE_EXECUTE && is_crc32_b2 && !rx_full && !action_busy;
  assign crc_push_b3 = state == STATE_EXECUTE && is_crc32_b3 && !rx_full && !action_busy;

  // Action program: E8/E9 slot,data — write fires when data byte arrives.
  assign action_wr_lo =
      state == STATE_OPERAND_HIGH_WAIT && is_action_wr_lo && action_control_ready;
  assign action_wr_hi =
      state == STATE_OPERAND_HIGH_WAIT && is_action_wr_hi && action_control_ready;
  assign action_wr_lane_lo =
      state == STATE_OPERAND_HIGH_WAIT && is_action_wr_lane_lo && action_control_ready;
  assign action_wr_lane_hi =
      state == STATE_OPERAND_HIGH_WAIT && is_action_wr_lane_hi && action_control_ready;
  // RUN_REGION id: start on low operand; RUN_REGION id,count on high.
  assign action_start =
      ((state == STATE_OPERAND_LOW_WAIT && is_run_region) ||
       (state == STATE_OPERAND_HIGH_WAIT && is_run_region_n)) &&
      action_start_ready;
  assign action_load_shift =
      state == STATE_OPERAND_LOW_WAIT && is_action_load_sh && action_control_ready;
  assign action_load_shift_hi =
      state == STATE_OPERAND_LOW_WAIT && is_action_load_hi && action_control_ready;
  assign action_load_tx =
      state == STATE_OPERAND_LOW_WAIT && is_action_tx_load && !tx_empty &&
      action_control_ready;
  assign action_read_result =
      state == STATE_OPERAND_LOW_WAIT && is_read_result && action_control_ready;
  assign action_push_result =
      state == STATE_OPERAND_LOW_WAIT && is_action_push && !rx_full &&
      action_control_ready;
  assign wait_region_active = state == STATE_REGION_WAIT;
  assign wait_region_clear =
      state == STATE_REGION_WAIT && event_wait_matched;

  assign tx_pop = execute_tx_load || action_load_tx;
  assign rx_push =
      (state == STATE_EXECUTE && opcode == 4'h7 && !rx_full && !action_busy) ||
      crc_push_lo || crc_push_hi || ev_stamp ||
      crc_push_b2 || crc_push_b3 || ev_detail || action_push_result;

  always @(posedge clk) begin
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
    end else if (!enable) begin
      state <= STATE_IDLE;
      program_counter <= 10'b0;
      halted <= 1'b0;
      sideset_pending <= 1'b0;
      crc_issued <= 1'b0;
    end else begin
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
        STATE_EXECUTE: begin
          if (!cpu_pin_conflict) begin
          // Side-set applies at instruction start, then clears (unless the
          // current instruction is itself a prefix, which chains).
          if (sideset_pending && !is_sideset)
            sideset_pending <= 1'b0;
          case (opcode)
            4'h0: begin
              if (immediate == 4'h1) begin
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
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h1, 4'h8, 4'hf,
            4'hb, 4'hd: begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_OPERAND_LOW_REQUEST;
            end
            4'hc: begin
              if (is_action_tx_load) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'he: begin
              if (immediate == 4'h0) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else if (is_crc32_setup) begin
                if (!crc_busy) begin
                  program_counter <= program_counter + 1'b1;
                  state <= STATE_FETCH_REQUEST;
                end
              end else if (is_crc32_b2 || is_crc32_b3 || is_ev_detail) begin
                if (!rx_full && !action_busy) begin
                  program_counter <= program_counter + 1'b1;
                  state <= STATE_FETCH_REQUEST;
                end
              end else if (is_wait_region) begin
                state <= STATE_REGION_WAIT;
              end else if (is_run_region || is_run_region_n ||
                           is_read_result || is_action_wr_lo ||
                           is_action_wr_hi || is_action_wr_lane_lo ||
                           is_action_wr_lane_hi || is_action_load_sh ||
                           is_action_load_hi || is_action_push) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'ha: begin
              if (is_crc_fin) begin
                if (!crc_issued && !crc_busy)
                  crc_issued <= 1'b1;
                else if (crc_issued && !crc_busy) begin
                  crc_issued <= 1'b0;
                  program_counter <= program_counter + 1'b1;
                  state <= STATE_FETCH_REQUEST;
                end
              end else if (immediate == 4'h0) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end else if (is_crc_lo || is_crc_hi) begin
                if (!rx_full && !action_busy) begin
                  program_counter <= program_counter + 1'b1;
                  state <= STATE_FETCH_REQUEST;
                end
              end else if (is_ev_stamp) begin
                if (!rx_full && !action_busy) begin
                  program_counter <= program_counter + 1'b1;
                  state <= STATE_FETCH_REQUEST;
                end
              end else if (is_crc_setup || is_crc_feed || is_alu_mov) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else if (is_alu_set || is_alu_op) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else if (is_get_time || is_wait_until) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h4: begin
              if (!tx_empty && !action_busy) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h5, 4'h6: begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
            4'h7: begin
              if (!rx_full && !action_busy) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h9: begin
              if (pin_wait_satisfied) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            default: begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          endcase
          end
        end
        STATE_OPERAND_LOW_REQUEST: state <= STATE_OPERAND_LOW_WAIT;
        STATE_OPERAND_LOW_WAIT: begin
          operand_low <= instruction_data;
          if (is_action_tx_load) begin
            if (!tx_empty && action_control_ready) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (is_crc_feed) begin
            if (!crc_issued && !crc_busy)
              crc_issued <= 1'b1;
            else if (crc_issued && !crc_busy) begin
              crc_issued <= 1'b0;
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (opcode == 4'hb || is_alu_mov || is_get_time || is_read_result ||
              is_action_load_sh || is_action_load_hi) begin
            if ((!is_read_result && !is_action_load_sh && !is_action_load_hi) ||
                action_control_ready) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (is_action_push) begin
            if (!rx_full && action_control_ready) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (is_run_region) begin
            if (action_start_ready) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (is_wait_until) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_TIME_WAIT;
          end else if (opcode == 4'hd) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_EVENT_WAIT;
          end else begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_OPERAND_HIGH_REQUEST;
          end
        end
        STATE_OPERAND_HIGH_REQUEST: state <= STATE_OPERAND_HIGH_WAIT;
        STATE_OPERAND_HIGH_WAIT: begin
          if (opcode == 4'h1) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_TIMER_WAIT;
          end else if (is_action_wr_lo || is_action_wr_hi ||
                       is_action_wr_lane_lo || is_action_wr_lane_hi) begin
            if (action_control_ready) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (is_run_region_n) begin
            if (action_start_ready) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else if (opcode == 4'he || opcode == 4'hf) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end else if (is_crc_setup) begin
            operand_mid <= instruction_data;
            program_counter <= program_counter + 1'b1;
            state <= STATE_OPERAND_EXT_REQUEST;
          end else if (is_alu_set || is_alu_op) begin
            operand_mid <= instruction_data;
            program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end else if (opcode == 4'h8) begin
            if (branch_taken)
              program_counter <= {instruction_data[1:0], operand_low};
            else
              program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end else begin
            program_counter <= {instruction_data[1:0], operand_low};
            state <= STATE_FETCH_REQUEST;
          end
        end
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
            program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end
        end
        STATE_EVENT_WAIT: begin
          if (event_wait_matched)
            state <= STATE_FETCH_REQUEST;
        end
        STATE_REGION_WAIT: begin
          if (event_wait_matched) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end
        end
        STATE_TIME_WAIT: begin
          if (time_satisfied)
            state <= STATE_FETCH_REQUEST;
        end
        STATE_TIMER_WAIT: begin
          if (timer_expired)
            state <= STATE_FETCH_REQUEST;
        end
        STATE_HALTED: begin
          halted <= 1'b1;
          state <= STATE_HALTED;
        end
        default: state <= STATE_IDLE;
      endcase
    end
  end

  wire _unused_decode = &{decoder_branch, decoder_delay, decoder_gpio,
                          decoder_shift, decoder_event};
endmodule

`default_nettype wire
