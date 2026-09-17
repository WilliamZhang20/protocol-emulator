`default_nettype none

// Top-level protocol engine: wires the sequencer to shared resources.
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
  wire [3:0] state;
  wire [9:0] program_counter;
  wire [7:0] instruction;
  wire [7:0] operand_low;
  wire [7:0] operand_mid;
  wire [7:0] operand_ext;
  wire       operand_ext_valid;
  wire       idle_clear;
  wire [3:0] opcode;
  wire [3:0] immediate;

  wire execute_gpio_write;
  wire execute_oe_write;
  wire execute_shift_out;
  wire execute_map;
  wire execute_tx_load;
  wire execute_shift_in;
  wire execute_shift_clear;
  wire timer_load;
  wire timer_async;
  wire timer_count_enable;
  wire bit_xfer_start;
  wire [7:0] xfer_half_period;
  wire arm_edges;
  wire wait_event_clear;

  wire bit_xfer_busy;
  wire bit_xfer_done;
  wire event_wait_matched;
  wire timer_expired;
  wire [7:0] gpio_sampled;
  wire [7:0] gpio_rising;
  wire [7:0] gpio_falling;
  wire gpio_compare_match;
  wire pin_wait_satisfied =
      gpio_sampled[immediate[2:0]] == immediate[3];

  vm_sequencer sequencer (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .instruction_data(instruction_data),
      .tx_empty(tx_empty),
      .rx_full(rx_full),
      .bit_xfer_busy(bit_xfer_busy),
      .event_wait_matched(event_wait_matched),
      .timer_expired(timer_expired),
      .pin_wait_satisfied(pin_wait_satisfied),
      .state(state),
      .program_counter(program_counter),
      .instruction(instruction),
      .operand_low(operand_low),
      .operand_mid(operand_mid),
      .operand_ext(operand_ext),
      .operand_ext_valid(operand_ext_valid),
      .halted(halted),
      .instruction_read(instruction_read),
      .idle_clear(idle_clear),
      .opcode(opcode),
      .immediate(immediate),
      .execute_gpio_write(execute_gpio_write),
      .execute_oe_write(execute_oe_write),
      .execute_shift_out(execute_shift_out),
      .execute_map(execute_map),
      .execute_tx_load(execute_tx_load),
      .execute_shift_in(execute_shift_in),
      .execute_shift_clear(execute_shift_clear),
      .timer_load(timer_load),
      .timer_async(timer_async),
      .timer_count_enable(timer_count_enable),
      .bit_xfer_start(bit_xfer_start),
      .xfer_half_period(xfer_half_period),
      .arm_edges(arm_edges),
      .wait_event_clear(wait_event_clear),
      .tx_pop(tx_pop),
      .rx_push(rx_push)
  );

  wire [15:0] timer_count;
  wire timer_busy;
  wire timer_done_pulse;

  timer_counter timer (
      .clk(clk),
      .rst_n(rst_n),
      .load(timer_load),
      .count_enable(timer_count_enable),
      .async_start(timer_async),
      .load_value({instruction_data, operand_low}),
      .count_value(timer_count),
      .expired(timer_expired),
      .busy(timer_busy),
      .done_pulse(timer_done_pulse)
  );

  wire engine_drive_enable;
  wire [7:0] engine_out_value;
  wire [7:0] engine_out_mask;
  wire [7:0] engine_oe_value;
  wire [7:0] engine_oe_mask;
  wire shifter_serial_out;
  wire [15:0] shifter_parallel;
  wire shifter_done;
  wire [7:0] xfer_pin_claim;
  wire gpio_output_write;
  wire [7:0] gpio_value;
  wire [7:0] gpio_output_mask;
  wire [7:0] gpio_oe_value;
  wire [7:0] gpio_oe_mask;
  wire [7:0] start_claim =
      (8'b1 << operand_mid[2:0]) | (8'b1 << immediate[2:0]);

  gpio_arbiter gpio_arb (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .force_clear(idle_clear),
      .bit_xfer_start(bit_xfer_start),
      .bit_xfer_done(bit_xfer_done),
      .start_claim(start_claim),
      .selected_pin(immediate[2:0]),
      .gpio_bit_value(execute_shift_out ? shifter_serial_out : immediate[3]),
      .oe_bit_value(immediate[3]),
      .execute_gpio_write(execute_gpio_write),
      .execute_oe_write(execute_oe_write),
      .execute_shift_out(execute_shift_out),
      .engine_drive_enable(engine_drive_enable),
      .engine_out_value(engine_out_value),
      .engine_out_mask(engine_out_mask),
      .engine_oe_value(engine_oe_value),
      .engine_oe_mask(engine_oe_mask),
      .pin_claim(xfer_pin_claim),
      .gpio_output_write(gpio_output_write),
      .gpio_value(gpio_value),
      .gpio_output_mask(gpio_output_mask),
      .gpio_oe_value(gpio_oe_value),
      .gpio_oe_mask(gpio_oe_mask)
  );

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
      .compare_value(immediate[3] ? (8'b1 << immediate[2:0]) : 8'b0),
      .compare_mask(8'b1 << immediate[2:0]),
      .sampled_value(gpio_sampled),
      .rising_edges(gpio_rising),
      .falling_edges(gpio_falling),
      .compare_match(gpio_compare_match)
  );

  bit_transfer_engine bit_xfer (
      .clk(clk),
      .rst_n(rst_n),
      .load(execute_tx_load || execute_shift_clear),
      .shift_enable(execute_shift_out || execute_shift_in),
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
      .cfg_half_period(xfer_half_period),
      .pin_sampled(gpio_sampled),
      .busy(bit_xfer_busy),
      .done(bit_xfer_done),
      .drive_enable(engine_drive_enable),
      .drive_out_value(engine_out_value),
      .drive_out_mask(engine_out_mask),
      .drive_oe_value(engine_oe_value),
      .drive_oe_mask(engine_oe_mask)
  );

  wire [7:0] event_pending;

  event_engine events (
      .clk(clk),
      .rst_n(rst_n),
      .xfer_done_pulse(bit_xfer_done),
      .timer_done_pulse(timer_done_pulse),
      .arm_edges(arm_edges),
      .rise_enable(operand_low),
      .fall_enable(instruction_data),
      .gpio_rising(gpio_rising),
      .gpio_falling(gpio_falling),
      .compare_match(gpio_compare_match),
      .compare_arm(immediate[0]),
      .wait_clear(wait_event_clear),
      .wait_mask(operand_low),
      .pending(event_pending),
      .wait_matched(event_wait_matched)
  );

  assign instruction_address = program_counter;
  assign rx_data = shifter_parallel[15:8];

  wire _unused = &{instruction, opcode, operand_ext, operand_ext_valid,
                   timer_count, timer_busy, gpio_compare_match,
                   shifter_parallel[7:0], shifter_done, event_pending, 1'b0};
endmodule

`default_nettype wire
