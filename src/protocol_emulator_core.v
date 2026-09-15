`default_nettype none

// Fetches and executes the SRAM-resident protocol program. The bytecode exposes
// protocol-neutral timing, GPIO, shifting, FIFO, pin-wait, mapping, and branch
// primitives; UART behavior is supplied entirely by SRAM contents.
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

  reg [3:0] state;
  reg [9:0] program_counter;
  reg [7:0] instruction;
  reg [7:0] operand_low;
  reg halted_register;

  wire [3:0] opcode;
  wire [3:0] immediate;
  wire decoder_branch;
  wire decoder_delay;
  wire decoder_gpio;
  wire decoder_shift;

  instruction_decoder decoder (
      .instruction(instruction),
      .opcode(opcode),
      .immediate(immediate),
      .branch_enable(decoder_branch),
      .delay_enable(decoder_delay),
      .gpio_enable(decoder_gpio),
      .shift_enable(decoder_shift)
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
  wire [7:0] selected_pin_mask = 8'b1 << immediate[2:0];
  wire execute_gpio_write = state == STATE_EXECUTE && opcode == 4'h2;
  wire execute_oe_write = state == STATE_EXECUTE && opcode == 4'h3;
  wire execute_shift_out = state == STATE_EXECUTE && opcode == 4'h5;
  wire execute_map = state == STATE_OPERAND_LOW_WAIT && opcode == 4'hb;
  wire gpio_output_write = execute_gpio_write || execute_oe_write ||
                           execute_shift_out;
  wire gpio_bit_value = execute_shift_out ? shifter_serial_out : immediate[3];
  wire [7:0] gpio_value = gpio_bit_value ? selected_pin_mask : 8'b0;
  wire [7:0] gpio_output_mask =
      (execute_gpio_write || execute_shift_out) ? selected_pin_mask : 8'b0;
  wire [7:0] gpio_oe_value = immediate[3] ? selected_pin_mask : 8'b0;
  wire [7:0] gpio_oe_mask = execute_oe_write ? selected_pin_mask : 8'b0;

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
  wire shifter_serial_out;
  wire [15:0] shifter_parallel;
  wire shifter_done;

  serial_shifter shifter (
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
      .done(shifter_done)
  );

  assign instruction_address = program_counter;
  assign instruction_read = state == STATE_FETCH_REQUEST ||
                            state == STATE_OPERAND_LOW_REQUEST ||
                            state == STATE_OPERAND_HIGH_REQUEST;
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
            4'h1, 4'h8, 4'hb: begin
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
          end else begin
            program_counter <= {instruction_data[1:0], operand_low};
            state <= STATE_FETCH_REQUEST;
          end
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
                   timer_count, gpio_rising, gpio_falling, gpio_compare_match,
                   shifter_done, 1'b0};
endmodule

`default_nettype wire
