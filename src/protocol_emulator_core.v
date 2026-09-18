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
  wire crc_setup;
  wire crc_feed;
  wire crc_finalize;
  wire crc_push_lo;
  wire crc_push_hi;
  wire line_cfg;
  wire line_drive;
  wire line_release;
  wire line_sample;
  wire alu_set;
  wire alu_mov;
  wire alu_op;
  wire djnz_strobe;
  wire alu_zero;
  wire djnz_nonzero;
  wire time_rd;
  wire time_wait_active;
  wire ev_stamp;
  wire time_satisfied;
  wire sideset_apply;
  wire [2:0] sideset_pin;
  wire sideset_val;
  wire crc_setup32;
  wire crc_push_b2;
  wire crc_push_b3;

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
      .alu_zero(alu_zero),
      .djnz_nonzero(djnz_nonzero),
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
      .rx_push(rx_push),
      .crc_setup(crc_setup),
      .crc_feed(crc_feed),
      .crc_finalize(crc_finalize),
      .crc_push_lo(crc_push_lo),
      .crc_push_hi(crc_push_hi),
      .line_cfg(line_cfg),
      .line_drive(line_drive),
      .line_release(line_release),
      .line_sample(line_sample),
      .alu_set(alu_set),
      .alu_mov(alu_mov),
      .alu_op(alu_op),
      .djnz_strobe(djnz_strobe),
      .time_rd(time_rd),
      .time_wait_active(time_wait_active),
      .ev_stamp(ev_stamp),
      .time_satisfied(time_satisfied),
      .sideset_apply(sideset_apply),
      .sideset_pin(sideset_pin),
      .sideset_val(sideset_val),
      .crc_setup32(crc_setup32),
      .crc_push_b2(crc_push_b2),
      .crc_push_b3(crc_push_b3)
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

  wire [31:0] crc_value;
  wire crc_busy;
  wire [7:0] crc_cfg = operand_low;
  wire [15:0] crc_poly = {
      (operand_ext_valid ? operand_ext : instruction_data),
      operand_mid
  };

  // Phase 1-2: central 8x16 register file + tiny ALU + zero flag.
  // Encodings are additive: 0xAA SET Rd,imm8 / 0xAB MOV Rd,Rs /
  // 0xAC ALU op,Rd,Rs. Branches 0x81 JZ / 0x82 JNZ / 0x88-0x8F DJNZ Rn
  // reuse the 2-byte jump operand format; 0x80 stays unconditional.
  wire [2:0] alu_set_rd = operand_low[2:0];
  wire [15:0] alu_set_val = {8'b0, instruction_data};
  wire [2:0] alu_mov_rd = instruction_data[2:0];
  wire [2:0] alu_mov_rs = instruction_data[5:3];
  wire [2:0] alu_op_sel = operand_low[2:0];
  wire [2:0] alu_op_rd = instruction_data[2:0];
  wire [2:0] alu_op_rs = instruction_data[5:3];
  wire is_branch_op = opcode == 4'h8;
  wire [2:0] rf_ra = alu_mov_rs;
  wire [2:0] rf_rb = time_wait_active ? operand_low[2:0] :
      is_branch_op ? immediate[2:0] :
      (alu_op ? alu_op_rd : alu_mov_rd);
  wire [15:0] rf_rd_a;
  wire [15:0] rf_rd_b;
  wire [15:0] alu_a = rf_rd_a;
  wire [15:0] alu_b = rf_rd_b;
  reg [15:0] alu_result;
  always @(*) begin
    case (alu_op_sel)
      3'd0: alu_result = alu_b + alu_a;
      3'd1: alu_result = alu_b - alu_a;
      3'd2: alu_result = alu_b & alu_a;
      3'd3: alu_result = alu_b | alu_a;
      3'd4: alu_result = alu_b ^ alu_a;
      3'd5: alu_result = alu_b << alu_a[3:0];
      3'd6: alu_result = alu_b >> alu_a[3:0];
      default: alu_result = alu_b + alu_a;
    endcase
  end
  wire [15:0] rf_wdata = djnz_strobe ? (rf_rd_b - 16'd1) :
      time_rd ? cycle_ctr[15:0] :
      alu_set ? alu_set_val :
      alu_mov ? alu_a :
      alu_op ? alu_result : 16'b0;
  wire [2:0] rf_waddr = djnz_strobe ? immediate[2:0] :
      (time_rd || alu_mov) ? alu_mov_rd :
      alu_set ? alu_set_rd :
      alu_op ? alu_op_rd : 3'b0;
  wire rf_we = alu_set || alu_mov || alu_op || djnz_strobe || time_rd;
  register_file regs (
      .clk(clk),
      .rst_n(rst_n),
      .read_address_a(rf_ra),
      .read_address_b(rf_rb),
      .read_data_a(rf_rd_a),
      .read_data_b(rf_rd_b),
      .write_enable(rf_we),
      .write_address(rf_waddr),
      .write_data(rf_wdata)
  );
  reg zero_flag;
  wire [15:0] alu_flag_val = time_rd ? cycle_ctr[15:0] :
      alu_set ? alu_set_val :
      alu_mov ? alu_a : alu_result;
  always @(posedge clk) begin
    if (!rst_n || !enable)
      zero_flag <= 1'b0;
    else if (alu_set || alu_mov || alu_op || time_rd)
      zero_flag <= (alu_flag_val == 16'b0);
  end
  assign alu_zero = zero_flag;
  assign djnz_nonzero = (rf_rd_b != 16'd1);

  // Phase 3: free-running global cycle counter, deterministic from enable.
  reg [31:0] cycle_ctr;
  always @(posedge clk) begin
    if (!rst_n || !enable)
      cycle_ctr <= 32'b0;
    else
      cycle_ctr <= cycle_ctr + 1'b1;
  end
  // WAIT_UNTIL Rn stalls in TIME_WAIT until ctr[15:0] >= Rn (unsigned).
  assign time_satisfied = cycle_ctr[15:0] >= rf_rd_b;

  crc_engine u_crc (
      .clk(clk),
      .rst_n(rst_n),
      .setup(crc_setup),
      .setup32(crc_setup32),
      .cfg(crc_cfg),
      .poly(crc_poly),
      .feed(crc_feed),
      .feed_byte(instruction_data),
      .finalize(crc_finalize),
      .crc(crc_value),
      .busy(crc_busy)
  );

  wire [7:0] line_claim;
  wire line_drive_enable;
  wire [7:0] line_out_value;
  wire [7:0] line_out_mask;
  wire [7:0] line_oe_value;
  wire [7:0] line_oe_mask;
  wire [1:0] line_sampled_state;
  wire [1:0] line_sample_comb;
  wire line_changed;

  line_pair lines (
      .clk(clk),
      .rst_n(rst_n),
      .cfg_write(line_cfg),
      .pin_a(instruction_data[2:0]),
      .pin_b(instruction_data[5:3]),
      .jk_swap(instruction_data[6]),
      .drive(line_drive),
      .drive_state(instruction_data[1:0]),
      .release_line(line_release),
      .sample(line_sample),
      .pin_sampled(gpio_sampled),
      .claim(line_claim),
      .drive_enable(line_drive_enable),
      .drive_out_value(line_out_value),
      .drive_out_mask(line_out_mask),
      .drive_oe_value(line_oe_value),
      .drive_oe_mask(line_oe_mask),
      .sampled_state(line_sampled_state),
      .sample_comb(line_sample_comb),
      .state_changed(line_changed)
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
      .line_claim(line_claim),
      .line_drive_enable(line_drive_enable),
      .line_out_value(line_out_value),
      .line_out_mask(line_out_mask),
      .line_oe_value(line_oe_value),
      .line_oe_mask(line_oe_mask),
      .selected_pin(immediate[2:0]),
      .gpio_bit_value(execute_shift_out ? shifter_serial_out : immediate[3]),
      .oe_bit_value(immediate[3]),
      .execute_gpio_write(execute_gpio_write),
      .execute_oe_write(execute_oe_write),
      .execute_shift_out(execute_shift_out),
      .sideset_apply(sideset_apply),
      .sideset_pin(sideset_pin),
      .sideset_val(sideset_val),
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
      .line_changed_pulse(line_changed),
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

  // Phase 4: timestamped event capture alongside the sticky scoreboard.
  // EVENT_STAMP (0xAF) pushes 3 bytes cycling time_lo/time_hi/cause.
  // The timestamp + pending vector latch on the first byte so the triple
  // is self-consistent. Index resets when the engine stops.
  reg [31:0] stamp_time;
  reg [7:0] stamp_cause;
  reg [1:0] stamp_idx;
  // Byte 0 pushes the live counter low byte (the registered latch lands the
  // same cycle, too late for the push); bytes 1-2 use the latched snapshot
  // so the triple is self-consistent.
  wire [7:0] stamp_byte = stamp_idx == 2'd0 ? cycle_ctr[7:0] :
      stamp_idx == 2'd1 ? stamp_time[15:8] : stamp_cause;
  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      stamp_time <= 32'b0;
      stamp_cause <= 8'b0;
      stamp_idx <= 2'b0;
    end else if (ev_stamp) begin
      if (stamp_idx == 2'd0) begin
        stamp_time <= cycle_ctr;
        stamp_cause <= event_pending;
      end
      if (stamp_idx == 2'd2)
        stamp_idx <= 2'b0;
      else
        stamp_idx <= stamp_idx + 1'b1;
    end
  end

  assign instruction_address = program_counter;
  assign rx_data =
      crc_push_lo ? crc_value[7:0] :
      crc_push_hi ? crc_value[15:8] :
      crc_push_b2 ? crc_value[23:16] :
      crc_push_b3 ? crc_value[31:24] :
      line_sample ? {6'b0, line_sample_comb} :
      ev_stamp ? stamp_byte :
      shifter_parallel[15:8];

  wire _unused = &{instruction, opcode, operand_ext, operand_ext_valid,
                   timer_count, timer_busy, gpio_compare_match,
                   shifter_parallel[7:0], shifter_done, event_pending,
                   crc_busy, xfer_pin_claim, state, line_sampled_state, 1'b0};
endmodule

`default_nettype wire
