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
  wire arm_edges;
  wire wait_event_clear;
  wire crc_setup;
  wire crc_feed;
  wire crc_finalize;
  wire crc_push_lo;
  wire crc_push_hi;
  wire alu_set;
  wire alu_mov;
  wire alu_op;
  wire djnz_strobe;
  wire alu_zero;
  wire djnz_nonzero;
  wire time_rd;
  wire time_wait_active;
  wire ev_stamp;
  wire ev_detail;
  wire time_satisfied;
  wire sideset_apply;
  wire [2:0] sideset_pin;
  wire sideset_val;
  wire [7:0] action_claim;
  wire crc_setup32;
  wire crc_push_b2;
  wire crc_push_b3;
  wire action_wr_lo;
  wire action_wr_hi;
  wire action_wr_lane_lo;
  wire action_wr_lane_hi;
  wire action_start;
  wire action_load_shift;
  wire action_load_shift_hi;
  wire action_load_tx;
  wire action_read_result;
  wire action_push_result;
  wire wait_region_active;
  wire wait_region_clear;
  wire action_busy;
  wire action_control_ready;
  wire action_start_ready;
  wire action_done;
  wire [1:0] action_done_count;
  wire action_done_lane;
  wire [15:0] action_result;
  wire crc_busy;

  wire event_wait_matched;
  wire timer_expired;
  wire [7:0] gpio_sampled;
  wire [7:0] gpio_timed;
  wire [7:0] gpio_rising;
  wire [7:0] gpio_falling;
  wire cpu_tx_pop;
  wire cpu_rx_push;
  wire gpio_compare_match;
  wire pin_wait_satisfied =
      gpio_sampled[immediate[2:0]] == immediate[3];
  // A region reserves its entire pin set at launch. A CPU pin operation
  // waits at the execute boundary until that region releases its claim.
  wire cpu_pin_conflict = action_busy &&
      (((opcode == 4'h2 || opcode == 4'h3 || opcode == 4'h5) &&
        action_claim[immediate[2:0]]) ||
       (sideset_apply && action_claim[sideset_pin]));

  vm_sequencer sequencer (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .instruction_data(instruction_data),
      .tx_empty(tx_empty),
      .rx_full(rx_full),
      .action_busy(action_busy),
      .action_control_ready(action_control_ready),
      .action_start_ready(action_start_ready),
      .cpu_pin_conflict(cpu_pin_conflict),
      .crc_busy(crc_busy),
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
      .arm_edges(arm_edges),
      .wait_event_clear(wait_event_clear),
      .tx_pop(cpu_tx_pop),
      .rx_push(cpu_rx_push),
      .crc_setup(crc_setup),
      .crc_feed(crc_feed),
      .crc_finalize(crc_finalize),
      .crc_push_lo(crc_push_lo),
      .crc_push_hi(crc_push_hi),
      .alu_set(alu_set),
      .alu_mov(alu_mov),
      .alu_op(alu_op),
      .djnz_strobe(djnz_strobe),
      .time_rd(time_rd),
      .time_wait_active(time_wait_active),
      .ev_stamp(ev_stamp),
      .ev_detail(ev_detail),
      .time_satisfied(time_satisfied),
      .sideset_apply(sideset_apply),
      .sideset_pin(sideset_pin),
      .sideset_val(sideset_val),
      .crc_setup32(crc_setup32),
      .crc_push_b2(crc_push_b2),
      .crc_push_b3(crc_push_b3),
      .action_wr_lo(action_wr_lo),
      .action_wr_hi(action_wr_hi),
      .action_wr_lane_lo(action_wr_lane_lo),
      .action_wr_lane_hi(action_wr_lane_hi),
      .action_start(action_start),
      .action_load_shift(action_load_shift),
      .action_load_shift_hi(action_load_shift_hi),
      .action_load_tx(action_load_tx),
      .action_read_result(action_read_result),
      .action_push_result(action_push_result),
      .wait_region_active(wait_region_active),
      .wait_region_clear(wait_region_clear)
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
  // ALU Rs shares instruction_data[5:3] with MOV Rs (alu_mov_rs).
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
  // Phase 3: free-running global cycle counter, deterministic from enable.
  // Declared before RF write mux so Icarus can bind the reference.
  reg [31:0] cycle_ctr;
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
      action_read_result ? action_result :
      alu_set ? alu_set_val :
      alu_mov ? alu_a :
      alu_op ? alu_result : 16'b0;
  wire [2:0] rf_waddr = djnz_strobe ? immediate[2:0] :
      (time_rd || alu_mov || action_read_result) ? alu_mov_rd :
      alu_set ? alu_set_rd :
      alu_op ? alu_op_rd : 3'b0;
  wire rf_we = alu_set || alu_mov || alu_op || djnz_strobe || time_rd ||
      action_read_result;
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
      action_read_result ? action_result :
      alu_set ? alu_set_val :
      alu_mov ? alu_a : alu_result;
  always @(posedge clk) begin
    if (!rst_n || !enable)
      zero_flag <= 1'b0;
    else if (alu_set || alu_mov || alu_op || time_rd || action_read_result)
      zero_flag <= (alu_flag_val == 16'b0);
  end
  assign alu_zero = zero_flag;
  assign djnz_nonzero = (rf_rd_b != 16'd1);

  always @(posedge clk) begin
    if (!rst_n || !enable)
      cycle_ctr <= 32'b0;
    else
      cycle_ctr <= cycle_ctr + 1'b1;
  end
  // WAIT_UNTIL uses modular half-range comparison across 16-bit wrap.
  // Deadlines must be less than 32768 cycles from the current time.
  assign time_satisfied = $signed(cycle_ctr[15:0] - rf_rd_b) >= 0;

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

  wire action_drive_enable;
  wire [7:0] action_out_value;
  wire [7:0] action_out_mask;
  wire [7:0] action_oe_value;
  wire [7:0] action_oe_mask;
  wire action_tx_pop;
  wire action_rx_push;
  wire [7:0] action_rx_data;
  // E5 RUN_REGION id,count supplies count on the high operand byte.
  wire is_run_region_count = opcode == 4'he && immediate == 4'h5;
  // E4 start samples the slot from instruction_data on LOW_WAIT (operand_low
  // has not updated yet). E5 start uses the already-latched operand_low.
  wire [3:0] action_start_slot =
      is_run_region_count ? operand_low[3:0] : instruction_data[3:0];
  // Target byte bit 4 selects lane 1. Result/push/TX-load operands use bit 7
  // because their low bits retain their existing register/format fields.
  wire action_target_lane = state == 4'd7 ? operand_low[4] :
      (immediate == 4'h4 ? instruction_data[4] :
       ((immediate == 4'h7 || immediate == 4'hf ||
         (opcode == 4'hc && immediate == 4'h8)) ? instruction_data[7] : 1'b0));

  action_engine u_action (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .target_lane(action_target_lane),
      .wr_lo(action_wr_lo),
      .wr_hi(action_wr_hi),
      .wr_lane_lo(action_wr_lane_lo),
      .wr_lane_hi(action_wr_lane_hi),
      .wr_slot(operand_low[3:0]),
      .wr_data(instruction_data),
      .load_shift(action_load_shift),
      .load_shift_hi(action_load_shift_hi),
      .load_tx(action_load_tx),
      .tx_data(tx_data),
      .tx_empty(tx_empty),
      .tx_pop(action_tx_pop),
      .rx_full(rx_full),
      .rx_push(action_rx_push),
      .rx_data(action_rx_data),
      .tx_bits(instruction_data[4:0] == 5'd0 ? 5'd16 : instruction_data[4:0]),
      .tx_msb_first(instruction_data[5]),
      .shift_data(instruction_data),
      .start(action_start),
      .start_slot(action_start_slot),
      .repeat_count(is_run_region_count ? instruction_data : 8'b0),
      .pin_sampled(gpio_sampled),
      .pin_timed(gpio_timed),
      .busy(action_busy),
      .busy_mask(),
      .control_ready(action_control_ready),
      .table_ready(),
      .start_ready(action_start_ready),
      .done_pulse(action_done),
      .done_count(action_done_count),
      .done_lane(action_done_lane),
      .result(action_result),
      .lfsr_value(),
      .drive_enable(action_drive_enable),
      .drive_out_value(action_out_value),
      .drive_out_mask(action_out_mask),
      .drive_oe_value(action_oe_value),
      .drive_oe_mask(action_oe_mask),
      .claim(action_claim)
  );

  wire shifter_serial_out;
  wire [15:0] shifter_parallel;
  serial_shifter cpu_shifter (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .clear(execute_shift_clear),
      .load(execute_tx_load), .load_data(tx_data),
      .shift(execute_shift_out || execute_shift_in),
      .serial_in(gpio_sampled[immediate[2:0]]),
      .serial_out(shifter_serial_out), .parallel(shifter_parallel)
  );
  wire [7:0] action_pin_claim;
  wire gpio_output_write;
  wire [7:0] gpio_value;
  wire [7:0] gpio_output_mask;
  wire [7:0] gpio_oe_value;
  wire [7:0] gpio_oe_mask;

  gpio_arbiter gpio_arb (
      .action_claim(action_claim),
      .action_drive_enable(action_drive_enable),
      .action_out_value(action_out_value),
      .action_out_mask(action_out_mask),
      .action_oe_value(action_oe_value),
      .action_oe_mask(action_oe_mask),
      .selected_pin(immediate[2:0]),
      .gpio_bit_value(execute_shift_out ? shifter_serial_out : immediate[3]),
      .oe_bit_value(immediate[3]),
      .execute_gpio_write(execute_gpio_write),
      .execute_oe_write(execute_oe_write),
      .execute_shift_out(execute_shift_out),
      .sideset_apply(sideset_apply),
      .sideset_pin(sideset_pin),
      .sideset_val(sideset_val),
      .pin_claim(action_pin_claim),
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
      .timed_value(gpio_timed),
      .mapping_snapshot(),
      .rising_edges(gpio_rising),
      .falling_edges(gpio_falling),
      .compare_match(gpio_compare_match)
  );

  wire [7:0] event_pending;
  wire [7:0] event_detail;

  event_engine events (
      .clk(clk),
      .rst_n(rst_n),
      .timer_done_pulse(timer_done_pulse),
      .region_done_count(action_done_count),
      .region_done_lane(action_done_lane),
      .arm_edges(arm_edges),
      .rise_enable(operand_low),
      .fall_enable(instruction_data),
      .gpio_rising(gpio_rising),
      .gpio_falling(gpio_falling),
      .compare_match(gpio_compare_match),
      .compare_arm(immediate[0]),
      .wait_clear(wait_event_clear || wait_region_clear),
      .wait_mask(wait_region_active ? 8'h40 : operand_low),
      .pending(event_pending),
      .event_detail(event_detail),
      .wait_matched(event_wait_matched)
  );

  // Phase 4: timestamped event capture alongside the sticky scoreboard.
  // EVENT_STAMP (0xAF) pushes 3 bytes cycling time_lo/time_hi/cause.
  // The timestamp + pending vector latch on the first byte so the triple
  // is self-consistent. Index resets when the engine stops.
  // Only time_hi is latched: time_lo is read live from cycle_ctr[7:0].
  reg [7:0] stamp_time_hi;
  reg [7:0] stamp_cause;
  reg [7:0] stamp_detail;
  reg [1:0] stamp_idx;
  // Byte 0 pushes the live counter low byte (the registered latch lands the
  // same cycle, too late for the push); bytes 1-2 use the latched snapshot
  // so the triple is self-consistent.
  wire [7:0] stamp_byte = stamp_idx == 2'd0 ? cycle_ctr[7:0] :
      stamp_idx == 2'd1 ? stamp_time_hi : stamp_cause;
  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      stamp_time_hi <= 8'b0;
      stamp_cause <= 8'b0;
      stamp_detail <= 8'b0;
      stamp_idx <= 2'b0;
    end else if (ev_stamp) begin
      if (stamp_idx == 2'd0) begin
        stamp_time_hi <= cycle_ctr[15:8];
        stamp_cause <= event_pending;
        stamp_detail <= event_detail;
      end
      if (stamp_idx == 2'd2)
        stamp_idx <= 2'b0;
      else
        stamp_idx <= stamp_idx + 1'b1;
    end
  end

  assign instruction_address = program_counter;
  assign rx_data = action_rx_push ? action_rx_data :
      crc_push_lo ? crc_value[7:0] :
      crc_push_hi ? crc_value[15:8] :
      crc_push_b2 ? crc_value[23:16] :
      crc_push_b3 ? crc_value[31:24] :
      ev_detail ? stamp_detail :
      ev_stamp ? stamp_byte :
      action_push_result ? ((instruction_data[0] ? action_result[15:8] :
                             action_result[7:0]) << instruction_data[4:1]) :
      shifter_parallel[15:8];

  assign tx_pop = cpu_tx_pop || action_tx_pop;
  assign rx_push = cpu_rx_push || action_rx_push;

  wire _unused = &{instruction, opcode, operand_ext, operand_ext_valid,
                   timer_count, timer_busy, gpio_compare_match,
                   shifter_parallel[7:0], event_pending,
                   crc_busy, action_pin_claim, state, 1'b0};
endmodule

`default_nettype wire
