`default_nettype none

// Protocol engine: the control CPU (vm_sequencer) and the shared resources it
// steers -- register file and ALU, cycle counter, timer, CPU CRC, CPU serial
// shifter, event scoreboard, GPIO fabric, and the two-lane action engine.
// The program SRAM and the TX/RX FIFOs live one level up in project.v.
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
  // Sequencer encodings decoded outside the sequencer. These must match
  // vm_sequencer.
  localparam SEQ_OPERAND_HIGH_WAIT = 4'd7;
  localparam OP_PIN_WRITE  = 4'h2;
  localparam OP_OE_WRITE   = 4'h3;
  localparam OP_SHIFT_OUT  = 4'h5;
  localparam OP_BRANCH     = 4'h8;
  localparam OP_GROUP_C    = 4'hc;
  localparam OP_GROUP_E    = 4'he;

  // ---------------------------------------------------------------------------
  // Control CPU
  // ---------------------------------------------------------------------------
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
  wire crc_setup32;
  wire crc_feed;
  wire crc_finalize;
  wire crc_push_lo;
  wire crc_push_hi;
  wire crc_push_b2;
  wire crc_push_b3;
  wire alu_set;
  wire alu_mov;
  wire alu_op;
  wire djnz_strobe;
  wire time_rd;
  wire time_wait_active;
  wire ev_stamp;
  wire ev_detail;
  wire sideset_apply;
  wire [2:0] sideset_pin;
  wire sideset_val;
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
  wire cpu_tx_pop;
  wire cpu_rx_push;

  // Status fed back into the sequencer.
  wire alu_zero;
  wire djnz_nonzero;
  wire time_satisfied;
  wire timer_expired;
  wire crc_busy;
  wire event_wait_matched;
  wire action_busy;
  wire action_control_ready;
  wire action_start_ready;
  wire [7:0] action_claim;
  wire [7:0] gpio_sampled;

  // A lane using a FIFO port this cycle makes it unavailable to the CPU, so
  // CPU and lane transfers never collide on the single push/pop port.
  wire action_tx_pop;
  wire action_rx_push;
  wire cpu_tx_empty = tx_empty || action_tx_pop;
  wire cpu_rx_full = rx_full || action_rx_push;

  wire pin_wait_satisfied = gpio_sampled[immediate[2:0]] == immediate[3];

  // A region reserves its entire pin set at launch. A CPU pin write, OE
  // write, shift-out, or side-set to a reserved pin waits in EXECUTE until
  // the region releases its claim.
  wire cpu_pin_conflict = action_busy &&
      (((opcode == OP_PIN_WRITE || opcode == OP_OE_WRITE ||
         opcode == OP_SHIFT_OUT) && action_claim[immediate[2:0]]) ||
       (sideset_apply && action_claim[sideset_pin]));

  vm_sequencer sequencer (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .instruction_data(instruction_data),
      .tx_empty(cpu_tx_empty),
      .rx_full(cpu_rx_full),
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
      .time_satisfied(time_satisfied),
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

  assign instruction_address = program_counter;

  // ---------------------------------------------------------------------------
  // Cycle counter (GET_TIME, WAIT_UNTIL, EVENT_STAMP)
  // ---------------------------------------------------------------------------
  // Counts from engine enable, so time is deterministic per program.
  reg [31:0] cycle_ctr;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      cycle_ctr <= 32'b0;
    else if (!enable)
      cycle_ctr <= 32'b0;
    else
      cycle_ctr <= cycle_ctr + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Register file and ALU
  // ---------------------------------------------------------------------------
  // Register fields, by instruction:
  //   AA rd imm      SET         rd = operand_low[2:0]
  //   AB {rs,rd}     MOV         rs, rd = instruction_data[5:3], [2:0]
  //   AC op {rs,rd}  ALU         op = operand_low[2:0], rs/rd as MOV
  //   AD rd          GET_TIME    rd = instruction_data[2:0]
  //   AE rn          WAIT_UNTIL  rn = operand_low[2:0], read in TIME_WAIT
  //   88+n           DJNZ Rn     n = immediate[2:0]
  //   E7 select      READ_RESULT rd = operand_low[2:0], one cycle later
  wire [15:0] rs_value;
  wire [15:0] rd_value;
  wire [2:0] rs_index = instruction_data[5:3];
  wire [2:0] rd_index =
      time_wait_active      ? operand_low[2:0] :
      (opcode == OP_BRANCH) ? immediate[2:0] :
                              instruction_data[2:0];
  wire [2:0] alu_function = operand_low[2:0];

  reg [15:0] alu_result;
  always @(*) begin
    case (alu_function)
      3'd0: alu_result = rd_value + rs_value;
      3'd1: alu_result = rd_value - rs_value;
      3'd2: alu_result = rd_value & rs_value;
      3'd3: alu_result = rd_value | rs_value;
      3'd4: alu_result = rd_value ^ rs_value;
      3'd5: alu_result = rd_value << rs_value[3:0];
      3'd6: alu_result = rd_value >> rs_value[3:0];
      default: alu_result = rd_value + rs_value;
    endcase
  end

  wire [15:0] set_value = {8'b0, instruction_data};
  wire [15:0] action_result;

  wire rf_we = alu_set || alu_mov || alu_op || djnz_strobe || time_rd ||
      action_read_result;
  wire [2:0] rf_waddr =
      djnz_strobe          ? immediate[2:0] :
      action_read_result   ? operand_low[2:0] :
      (time_rd || alu_mov) ? instruction_data[2:0] :
      alu_set              ? operand_low[2:0] :
      alu_op               ? instruction_data[2:0] :
                             3'b0;
  wire [15:0] rf_wdata =
      djnz_strobe          ? rd_value - 16'd1 :
      time_rd              ? cycle_ctr[15:0] :
      action_read_result   ? action_result :
      alu_set              ? set_value :
      alu_mov              ? rs_value :
      alu_op               ? alu_result :
                             16'b0;

  register_file regs (
      .clk(clk),
      .rst_n(rst_n),
      .read_address_a(rs_index),
      .read_address_b(rd_index),
      .read_data_a(rs_value),
      .read_data_b(rd_value),
      .write_enable(rf_we),
      .write_address(rf_waddr),
      .write_data(rf_wdata)
  );

  // Zero flag for JZ/JNZ, updated by every register write except DJNZ.
  reg zero_flag;
  wire [15:0] flag_value =
      time_rd            ? cycle_ctr[15:0] :
      action_read_result ? action_result :
      alu_set            ? set_value :
      alu_mov            ? rs_value :
                           alu_result;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      zero_flag <= 1'b0;
    else if (!enable)
      zero_flag <= 1'b0;
    else if (alu_set || alu_mov || alu_op || time_rd || action_read_result)
      zero_flag <= (flag_value == 16'b0);
  end
  assign alu_zero = zero_flag;
  assign djnz_nonzero = rd_value != 16'd1;

  // WAIT_UNTIL compares modulo 2^16 over a half range: deadlines must be
  // less than 32768 cycles ahead of the current time.
  assign time_satisfied = $signed(cycle_ctr[15:0] - rd_value) >= 0;

  // ---------------------------------------------------------------------------
  // Timer (WAIT16 blocking, START_TIMER asynchronous)
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // CPU CRC (A1 cfg poly_lo poly_hi; poly_hi arrives in OPERAND_EXT_WAIT)
  // ---------------------------------------------------------------------------
  wire [31:0] crc_value;
  wire [15:0] crc_poly = {
      (operand_ext_valid ? operand_ext : instruction_data),
      operand_mid
  };

  crc_engine u_crc (
      .clk(clk),
      .rst_n(rst_n),
      .setup(crc_setup),
      .setup32(crc_setup32),
      .cfg(operand_low),
      .poly(crc_poly),
      .feed(crc_feed),
      .feed_byte(instruction_data),
      .finalize(crc_finalize),
      .crc(crc_value),
      .busy(crc_busy)
  );

  // ---------------------------------------------------------------------------
  // Action engine
  // ---------------------------------------------------------------------------
  wire action_drive_enable;
  wire [7:0] action_out_value;
  wire [7:0] action_out_mask;
  wire [7:0] action_oe_value;
  wire [7:0] action_oe_mask;
  wire [7:0] action_rx_data;
  wire [7:0] gpio_timed;
  wire action_done;
  wire [1:0] action_done_count;
  wire action_done_lane;

  // E5 RUN_REGION target,count: the target is already in operand_low and
  // the count is on instruction_data. E4 RUN_REGION target starts while its
  // target is still on instruction_data (operand_low updates on that edge).
  wire is_run_region_count = opcode == OP_GROUP_E && immediate == 4'h5;
  wire [3:0] action_start_slot =
      is_run_region_count ? operand_low[3:0] : instruction_data[3:0];

  // Lane select for the action operation issuing this cycle. Target bytes
  // use bit 4; select/config bytes use bit 7 because their low bits carry
  // other fields. Only the immediate is decoded, which is safe because the
  // value matters only while an action strobe is active.
  wire action_target_lane =
      // E7 READ_RESULT / EF PUSH_RESULT, one cycle after their operand.
      (action_read_result || action_push_result) ? operand_low[7] :
      // E5 count, E8/E9/EB/EC data: the target byte is already latched.
      (state == SEQ_OPERAND_HIGH_WAIT) ? operand_low[4] :
      // E4 target on instruction_data.
      (immediate == 4'h4) ? instruction_data[4] :
      // E7/EF acceptance and C8 config on instruction_data.
      (immediate == 4'h7 || immediate == 4'hf ||
       (opcode == OP_GROUP_C && immediate == 4'h8)) ? instruction_data[7] :
      // EA/EE shift preloads always target lane 0.
      1'b0;

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
      // A deferred PUSH_RESULT owns the RX port for its cycle.
      .rx_full(rx_full || action_push_result),
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

  // ---------------------------------------------------------------------------
  // CPU serial shifter (40 load, 5p/6p shift out/in, 70 push, A0 clear)
  // ---------------------------------------------------------------------------
  wire shifter_serial_out;
  wire [15:0] shifter_parallel;

  serial_shifter cpu_shifter (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .clear(execute_shift_clear),
      .load(execute_tx_load),
      .load_data(tx_data),
      .shift(execute_shift_out || execute_shift_in),
      .serial_in(gpio_sampled[immediate[2:0]]),
      .serial_out(shifter_serial_out),
      .parallel(shifter_parallel)
  );

  // ---------------------------------------------------------------------------
  // GPIO: CPU/lane merge, then the logical-to-physical fabric
  // ---------------------------------------------------------------------------
  wire [7:0] action_pin_claim;
  wire gpio_output_write;
  wire [7:0] gpio_value;
  wire [7:0] gpio_output_mask;
  wire [7:0] gpio_oe_value;
  wire [7:0] gpio_oe_mask;
  wire [7:0] gpio_rising;
  wire [7:0] gpio_falling;
  wire gpio_compare_match;

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

  // The compare source takes {value, pin} from the immediate of whichever
  // instruction is current, every cycle.
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

  // ---------------------------------------------------------------------------
  // Event scoreboard (WAIT_EVENT, WAIT_REGION, ARM_EDGE)
  // ---------------------------------------------------------------------------
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
      // WAIT_REGION waits on bit 6 (EV_REGION_DONE) only.
      .wait_mask(wait_region_active ? 8'h40 : operand_low),
      .pending(event_pending),
      .event_detail(event_detail),
      .wait_matched(event_wait_matched)
  );

  // ---------------------------------------------------------------------------
  // EVENT_STAMP (AF) and EVENT_DETAIL (ED)
  // ---------------------------------------------------------------------------
  // Three consecutive AF pushes emit time_lo, time_hi, and the pending
  // vector. The first push sends the live counter low byte (the snapshot
  // registers load on that same edge, too late for it) and snapshots
  // time_hi, pending, and detail so the triple is self-consistent. ED pushes
  // the detail snapshot. The index resets when the engine stops.
  reg [7:0] stamp_time_hi;
  reg [7:0] stamp_cause;
  reg [7:0] stamp_detail;
  reg [1:0] stamp_idx;
  wire [7:0] stamp_byte =
      stamp_idx == 2'd0 ? cycle_ctr[7:0] :
      stamp_idx == 2'd1 ? stamp_time_hi :
                          stamp_cause;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stamp_time_hi <= 8'b0;
      stamp_cause <= 8'b0;
      stamp_detail <= 8'b0;
      stamp_idx <= 2'b0;
    end else if (!enable) begin
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

  // ---------------------------------------------------------------------------
  // FIFO ports
  // ---------------------------------------------------------------------------
  wire [7:0] push_result_byte =
      (operand_low[0] ? action_result[15:8] : action_result[7:0]) <<
      operand_low[4:1];

  assign rx_data =
      action_rx_push     ? action_rx_data :
      crc_push_lo        ? crc_value[7:0] :
      crc_push_hi        ? crc_value[15:8] :
      crc_push_b2        ? crc_value[23:16] :
      crc_push_b3        ? crc_value[31:24] :
      ev_detail          ? stamp_detail :
      ev_stamp           ? stamp_byte :
      action_push_result ? push_result_byte :
                           shifter_parallel[15:8];

  assign tx_pop = cpu_tx_pop || action_tx_pop;
  assign rx_push = cpu_rx_push || action_rx_push;

  wire _unused = &{instruction, operand_ext, timer_count, timer_busy,
                   shifter_parallel[7:0], action_pin_claim, action_done,
                   1'b0};
endmodule

`default_nettype wire
