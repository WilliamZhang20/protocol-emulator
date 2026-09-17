`default_nettype none

// Fetches and executes the SRAM-resident protocol program. The bytecode exposes
// protocol-neutral timing, GPIO, shifting, autonomous bit-transfer, FIFO,
// pin-wait, mapping, and branch primitives; protocol behavior is supplied by
// SRAM contents.
module protocol_emulator_core (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    output wire [9:0] instruction_address,
    output wire       instruction_read,
    input  wire [7:0] instruction_data,
    input  wire [7:0] tx_data,
    input  wire       tx_empty,
    output wire       tx_pop,
    output wire [7:0] rx_data,
    output wire       rx_push,
    input  wire       rx_full,
    input  wire [7:0] gpio_in,
    output wire [7:0] gpio_out,
    output wire [7:0] gpio_oe,
    output wire       halted
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
  localparam STATE_BIT_XFER_WAIT = 4'd12;

  reg [3:0] state;
  reg [9:0] program_counter;
  reg [7:0] instruction;
  reg [7:0] operand_low;
  reg [7:0] operand_mid;
  reg halted_register;

  wire [3:0] opcode;
  wire [3:0] immediate;
  wire decoder_branch;
  wire decoder_delay;
  wire decoder_gpio;
  wire decoder_shift;
  wire decoder_bit_xfer;

  instruction_decoder decoder (
      .instruction(instruction),
      .opcode(opcode),
      .immediate(immediate),
      .branch_enable(decoder_branch),
      .delay_enable(decoder_delay),
      .gpio_enable(decoder_gpio),
      .shift_enable(decoder_shift),
      .bit_xfer_enable(decoder_bit_xfer)
  );

  wire [15:0] timer_count;
  wire timer_expired;
  wire timer_load = state == STATE_OPERAND_HIGH_WAIT && opcode == 4'h1;
  wire timer_count_enable = state == STATE_TIMER_WAIT;
  wire [15:0] timer_load_value = {instruction_data, operand_low};

  timer_counter timer (
      .clk(clk),
      .rst_n(rst_n),
      .load(timer_load),
      .count_enable(timer_count_enable),
      .load_value(timer_load_value),
      .count_value(timer_count),
      .expired(timer_expired)
  );

  wire [7:0] gpio_sampled;
  wire [7:0] gpio_rising;
  wire [7:0] gpio_falling;
  wire gpio_compare_match;
  wire shifter_serial_out;
  wire [7:0] selected_pin_mask = 8'b1 << immediate[2:0];
  wire execute_gpio_write = state == STATE_EXECUTE && opcode == 4'h2;
  wire execute_oe_write = state == STATE_EXECUTE && opcode == 4'h3;
  wire execute_shift_out = state == STATE_EXECUTE && opcode == 4'h5;
  wire execute_map = state == STATE_OPERAND_LOW_WAIT && opcode == 4'hb;

  wire engine_drive_enable;
  wire [7:0] engine_out_value;
  wire [7:0] engine_out_mask;
  wire [7:0] engine_oe_value;
  wire [7:0] engine_oe_mask;

  wire gpio_output_write = execute_gpio_write || execute_oe_write ||
                           execute_shift_out || engine_drive_enable;
  wire gpio_bit_value = execute_shift_out ? shifter_serial_out : immediate[3];
  wire [7:0] gpio_value = engine_drive_enable ? engine_out_value :
                          (gpio_bit_value ? selected_pin_mask : 8'b0);
  wire [7:0] gpio_output_mask =
      engine_drive_enable ? engine_out_mask :
      ((execute_gpio_write || execute_shift_out) ? selected_pin_mask : 8'b0);
  wire [7:0] gpio_oe_value = engine_drive_enable ? engine_oe_value :
                             (immediate[3] ? selected_pin_mask : 8'b0);
  wire [7:0] gpio_oe_mask = engine_drive_enable ? engine_oe_mask :
                            (execute_oe_write ? selected_pin_mask : 8'b0);

  gpio_datapath gpio (
      .clk(clk),
      .rst_n(rst_n),
      .pin_in(gpio_in),
      .pin_out(gpio_out),
      .pin_oe(gpio_oe),
      .map_write(execute_map),
      .logical_pin(immediate[2:0]),
      .physical_pin(instruction_data[2:0]),
      .output_write(gpio_output_write),
      .output_value(gpio_value),
      .output_mask(gpio_output_mask),
      .oe_value(gpio_oe_value),
      .oe_mask(gpio_oe_mask),
      .compare_value(immediate[3] ? selected_pin_mask : 8'b0),
      .compare_mask(selected_pin_mask),
      .sampled_value(gpio_sampled),
      .rising_edges(gpio_rising),
      .falling_edges(gpio_falling),
      .compare_match(gpio_compare_match)
  );

  wire execute_tx_load = state == STATE_EXECUTE && opcode == 4'h4 && !tx_empty;
  wire execute_shift_in = state == STATE_EXECUTE && opcode == 4'h6;
  wire execute_shift_clear = state == STATE_EXECUTE && opcode == 4'ha;
  wire shifter_load = execute_tx_load || execute_shift_clear;
  wire shifter_shift = execute_shift_out || execute_shift_in;
  wire [15:0] shifter_parallel;
  wire shifter_done;
  wire bit_xfer_busy;
  wire bit_xfer_done;
  // Pulse start while the half-period operand is still on instruction_data.
  wire bit_xfer_start = state == STATE_OPERAND_EXT_WAIT;

  // BIT_XFER operands:
  //   instruction[2:0] = clk_pin
  //   operand_low      = {tx_od, sample_phase, clk_idle, msb_first, bit_count_m1[3:0]}
  //   operand_mid      = {wait_clk_high, clk_od, rx_pin[2:0], tx_pin[2:0]}
  //   instruction_data = half_period
  bit_transfer_engine bit_xfer (
      .clk(clk),
      .rst_n(rst_n),
      .load(shifter_load),
      .shift_enable(shifter_shift),
      .shift_right(1'b1),
      .serial_in(gpio_sampled[immediate[2:0]]),
      .parallel_in(execute_tx_load ? {8'b0, tx_data} : 16'b0),
      .bit_count(5'd8),
      .serial_out(shifter_serial_out),
      .parallel_out(shifter_parallel),
      .shift_done(shifter_done),
      .start(bit_xfer_start),
      .cfg_bit_count_m1(operand_low[3:0]),
      .cfg_msb_first(operand_low[4]),
      .cfg_clk_idle(operand_low[5]),
      .cfg_sample_phase(operand_low[6]),
      .cfg_tx_open_drain(operand_low[7]),
      .cfg_clk_open_drain(operand_mid[6]),
      .cfg_wait_clk_high(operand_mid[7]),
      .cfg_tx_pin(operand_mid[2:0]),
      .cfg_rx_pin(operand_mid[5:3]),
      .cfg_clk_pin(immediate[2:0]),
      .cfg_half_period(instruction_data),
      .pin_sampled(gpio_sampled),
      .busy(bit_xfer_busy),
      .done(bit_xfer_done),
      .drive_enable(engine_drive_enable),
      .drive_out_value(engine_out_value),
      .drive_out_mask(engine_out_mask),
      .drive_oe_value(engine_oe_value),
      .drive_oe_mask(engine_oe_mask)
  );

  assign instruction_address = program_counter;
  assign instruction_read = state == STATE_FETCH_REQUEST ||
                            state == STATE_OPERAND_LOW_REQUEST ||
                            state == STATE_OPERAND_HIGH_REQUEST ||
                            state == STATE_OPERAND_EXT_REQUEST;
  assign tx_pop = execute_tx_load;
  assign rx_data = shifter_parallel[15:8];
  assign rx_push = state == STATE_EXECUTE && opcode == 4'h7 && !rx_full;
  assign halted = halted_register;

  wire pin_wait_satisfied =
      gpio_sampled[immediate[2:0]] == immediate[3];

  always @(posedge clk) begin
    if (!rst_n) begin
      state <= STATE_IDLE;
      program_counter <= 10'b0;
      instruction <= 8'b0;
      operand_low <= 8'b0;
      operand_mid <= 8'b0;
      halted_register <= 1'b0;
    end else if (!enable) begin
      state <= STATE_IDLE;
      program_counter <= 10'b0;
      halted_register <= 1'b0;
    end else begin
      case (state)
        STATE_IDLE: begin
          program_counter <= 10'b0;
          halted_register <= 1'b0;
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
                halted_register <= 1'b1;
                state <= STATE_HALTED;
              end else begin
                program_counter <= program_counter + 1'b1;
                state <= STATE_FETCH_REQUEST;
              end
            end
            4'h1, 4'h8, 4'hb, 4'hc: begin
              program_counter <= program_counter + 1'b1;
              state <= STATE_OPERAND_LOW_REQUEST;
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
          if (opcode == 4'hb)
            state <= STATE_FETCH_REQUEST;
          else
            state <= STATE_OPERAND_HIGH_REQUEST;
        end
        STATE_OPERAND_HIGH_REQUEST: state <= STATE_OPERAND_HIGH_WAIT;
        STATE_OPERAND_HIGH_WAIT: begin
          if (opcode == 4'h1) begin
            program_counter <= program_counter + 1'b1;
            state <= STATE_TIMER_WAIT;
          end else if (opcode == 4'hc) begin
            operand_mid <= instruction_data;
            program_counter <= program_counter + 1'b1;
            state <= STATE_OPERAND_EXT_REQUEST;
          end else begin
            program_counter <= {instruction_data[1:0], operand_low};
            state <= STATE_FETCH_REQUEST;
          end
        end
        STATE_OPERAND_EXT_REQUEST: state <= STATE_OPERAND_EXT_WAIT;
        STATE_OPERAND_EXT_WAIT: begin
          program_counter <= program_counter + 1'b1;
          state <= STATE_BIT_XFER_WAIT;
        end
        STATE_BIT_XFER_WAIT: begin
          if (!bit_xfer_busy)
            state <= STATE_FETCH_REQUEST;
        end
        STATE_TIMER_WAIT: begin
          if (timer_expired)
            state <= STATE_FETCH_REQUEST;
        end
        STATE_HALTED: begin
          halted_register <= 1'b1;
          state <= STATE_HALTED;
        end
        default: state <= STATE_IDLE;
      endcase
    end
  end

  wire _unused = &{decoder_branch, decoder_delay, decoder_gpio, decoder_shift,
                   decoder_bit_xfer, timer_count, gpio_rising, gpio_falling,
                   gpio_compare_match, shifter_parallel[7:0], shifter_done,
                   bit_xfer_done, 1'b0};
endmodule

`default_nettype wire
