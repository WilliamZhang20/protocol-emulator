`default_nettype none

// Instruction fetch/execute FSM plus decoded resource strobes.
// Opcode 0xA immediate sub-ops: shift-clear, CRC, and line_pair controls.
module vm_sequencer (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire [7:0] instruction_data,
    input  wire       tx_empty,
    input  wire       rx_full,
    input  wire       bit_xfer_busy,
    input  wire       event_wait_matched,
    input  wire       timer_expired,
    input  wire       pin_wait_satisfied,
    output reg  [3:0] state,
    output reg  [9:0] program_counter,
    output reg  [7:0] instruction,
    output reg  [7:0] operand_low,
    output reg  [7:0] operand_mid,
    output reg  [7:0] operand_ext,
    output reg        operand_ext_valid,
    output reg        halted,
    output wire       instruction_read,
    output wire       idle_clear,
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
    output wire       bit_xfer_start,
    output wire [7:0] xfer_half_period,
    output wire       arm_edges,
    output wire       wait_event_clear,
    output wire       tx_pop,
    output wire       rx_push,
    output wire       crc_setup,
    output wire       crc_feed,
    output wire       crc_finalize,
    output wire       crc_push_lo,
    output wire       crc_push_hi,
    output wire       line_cfg,
    output wire       line_drive,
    output wire       line_release,
    output wire       line_sample
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

  wire decoder_branch;
  wire decoder_delay;
  wire decoder_gpio;
  wire decoder_shift;
  wire decoder_bit_xfer;
  wire decoder_event;

  instruction_decoder decoder (
      .instruction(instruction),
      .opcode(opcode),
      .immediate(immediate),
      .branch_enable(decoder_branch),
      .delay_enable(decoder_delay),
      .gpio_enable(decoder_gpio),
      .shift_enable(decoder_shift),
      .bit_xfer_enable(decoder_bit_xfer),
      .event_enable(decoder_event)
  );

  wire is_crc_setup = opcode == 4'ha && immediate == 4'h1;
  wire is_crc_feed = opcode == 4'ha && immediate == 4'h2;
  wire is_crc_fin = opcode == 4'ha && immediate == 4'h3;
  wire is_crc_lo = opcode == 4'ha && immediate == 4'h4;
  wire is_crc_hi = opcode == 4'ha && immediate == 4'h5;
  wire is_line_cfg = opcode == 4'ha && immediate == 4'h6;
  wire is_line_drv = opcode == 4'ha && immediate == 4'h7;
  wire is_line_rel = opcode == 4'ha && immediate == 4'h8;
  wire is_line_sam = opcode == 4'ha && immediate == 4'h9;

  assign idle_clear = state == STATE_IDLE;
  assign instruction_read =
      state == STATE_FETCH_REQUEST ||
      state == STATE_OPERAND_LOW_REQUEST ||
      state == STATE_OPERAND_HIGH_REQUEST ||
      state == STATE_OPERAND_EXT_REQUEST;

  assign execute_gpio_write = state == STATE_EXECUTE && opcode == 4'h2;
  assign execute_oe_write = state == STATE_EXECUTE && opcode == 4'h3;
  assign execute_shift_out = state == STATE_EXECUTE && opcode == 4'h5;
  assign execute_map = state == STATE_OPERAND_LOW_WAIT && opcode == 4'hb;
  assign execute_tx_load = state == STATE_EXECUTE && opcode == 4'h4 && !tx_empty;
  assign execute_shift_in = state == STATE_EXECUTE && opcode == 4'h6;
  assign execute_shift_clear =
      state == STATE_EXECUTE && opcode == 4'ha && immediate == 4'h0;

  assign timer_load = state == STATE_OPERAND_HIGH_WAIT &&
                      (opcode == 4'h1 || opcode == 4'he);
  assign timer_async = state == STATE_OPERAND_HIGH_WAIT && opcode == 4'he;
  assign timer_count_enable = state == STATE_TIMER_WAIT;

  assign bit_xfer_start =
      state == STATE_OPERAND_EXT_WAIT && opcode == 4'hc && !bit_xfer_busy;
  assign xfer_half_period = operand_ext_valid ? operand_ext : instruction_data;

  assign arm_edges = state == STATE_OPERAND_HIGH_WAIT && opcode == 4'hf;
  assign wait_event_clear = state == STATE_EVENT_WAIT && event_wait_matched;

  // CRC_SETUP fires on first EXT_WAIT cycle (poly_hi on instruction_data).
  assign crc_setup =
      state == STATE_OPERAND_EXT_WAIT && is_crc_setup && !operand_ext_valid;
  assign crc_feed = state == STATE_OPERAND_LOW_WAIT && is_crc_feed;
  assign crc_finalize = state == STATE_EXECUTE && is_crc_fin;
  assign crc_push_lo = state == STATE_EXECUTE && is_crc_lo && !rx_full;
  assign crc_push_hi = state == STATE_EXECUTE && is_crc_hi && !rx_full;

  assign line_cfg = state == STATE_OPERAND_LOW_WAIT && is_line_cfg;
  assign line_drive = state == STATE_OPERAND_LOW_WAIT && is_line_drv;
  assign line_release = state == STATE_EXECUTE && is_line_rel;
  assign line_sample = state == STATE_EXECUTE && is_line_sam && !rx_full;

  assign tx_pop = execute_tx_load;
  assign rx_push =
      (state == STATE_EXECUTE && opcode == 4'h7 && !rx_full) ||
      crc_push_lo || crc_push_hi || line_sample;

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
    end else if (!enable) begin
      state <= STATE_IDLE;
      program_counter <= 10'b0;
      halted <= 1'b0;
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
          case (opcode)
            4'h0: begin
              if (immediate == 4'h1) begin
                halted <= 1'b1;
                state <= STATE_HALTED;
              end else begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h1, 4'h8, 4'hc, 4'he, 4'hf,
            4'hb, 4'hd: begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_OPERAND_LOW_REQUEST;
            end
            4'ha: begin
              if (immediate == 4'h0 || is_crc_fin || is_line_rel) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end else if (is_crc_lo || is_crc_hi || is_line_sam) begin
                if (!rx_full) begin
                  program_counter <= program_counter + 1'b1;
                  state <= STATE_FETCH_REQUEST;
                end
              end else if (is_crc_setup || is_crc_feed || is_line_cfg ||
                           is_line_drv) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_OPERAND_LOW_REQUEST;
              end else begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h4: begin
              if (!tx_empty) begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h7: begin
              if (!rx_full) begin
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
        STATE_OPERAND_LOW_REQUEST: state <= STATE_OPERAND_LOW_WAIT;
        STATE_OPERAND_LOW_WAIT: begin
          operand_low <= instruction_data;
          program_counter <= program_counter + 1'b1;
          if (opcode == 4'hb || is_crc_feed || is_line_cfg || is_line_drv)
            state <= STATE_FETCH_REQUEST;
          else if (opcode == 4'hd)
            state <= STATE_EVENT_WAIT;
          else
            state <= STATE_OPERAND_HIGH_REQUEST;
        end
        STATE_OPERAND_HIGH_REQUEST: state <= STATE_OPERAND_HIGH_WAIT;
        STATE_OPERAND_HIGH_WAIT: begin
          if (opcode == 4'h1) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_TIMER_WAIT;
          end else if (opcode == 4'he || opcode == 4'hf) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end else if (opcode == 4'hc || is_crc_setup) begin
            operand_mid <= instruction_data;
            program_counter <= program_counter + 1'b1;
            state <= STATE_OPERAND_EXT_REQUEST;
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
          if (!operand_ext_valid) begin
            operand_ext <= instruction_data;
            operand_ext_valid <= 1'b1;
          end
          if (opcode == 4'hc) begin
            if (!bit_xfer_busy) begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_FETCH_REQUEST;
            end
          end else begin
            // CRC_SETUP completes on the first EXT_WAIT cycle.
            program_counter <= program_counter + 1'b1;
            state <= STATE_FETCH_REQUEST;
          end
        end
        STATE_EVENT_WAIT: begin
          if (event_wait_matched)
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
                          decoder_shift, decoder_bit_xfer, decoder_event};
endmodule

`default_nettype wire
