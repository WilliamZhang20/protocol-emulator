`default_nettype none

module shared_resources_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  (* anyseq *) reg [7:0] instruction_data;
  (* anyseq *) reg tx_empty;
  (* anyseq *) reg rx_full;
  (* anyseq *) reg action_busy;
  (* anyseq *) reg action_table_ready;
  (* anyseq *) reg cpu_pin_conflict;
  (* anyseq *) reg crc_busy;
  (* anyseq *) reg event_wait_matched;
  (* anyseq *) reg timer_expired;
  (* anyseq *) reg pin_wait_satisfied;
  (* anyseq *) reg alu_zero;
  (* anyseq *) reg djnz_nonzero;
  (* anyseq *) reg time_satisfied;
  wire [3:0] state;
  wire [9:0] program_counter;
  wire [3:0] opcode;
  wire [3:0] immediate;
  wire [7:0] operand_low;
  wire halted;
  wire tx_pop;
  wire rx_push;
  wire crc_setup;
  wire crc_setup32;
  wire crc_feed;
  wire crc_finalize;
  wire crc_push_lo;
  wire crc_push_hi;
  wire crc_push_b2;
  wire crc_push_b3;
  wire execute_map;
  wire execute_shift_out;
  wire execute_shift_in;
  wire execute_shift_clear;
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

  vm_sequencer dut (
      .clk(clk), .rst_n(rst_n), .enable(1'b1),
      .instruction_data(instruction_data),
      .tx_empty(tx_empty), .rx_full(rx_full),
      .action_busy(action_busy),
      .action_table_ready(action_table_ready),
      .cpu_pin_conflict(cpu_pin_conflict),
      .crc_busy(crc_busy),
      .event_wait_matched(event_wait_matched),
      .timer_expired(timer_expired),
      .pin_wait_satisfied(pin_wait_satisfied),
      .alu_zero(alu_zero), .djnz_nonzero(djnz_nonzero),
      .time_satisfied(time_satisfied),
      .state(state), .program_counter(program_counter),
      .operand_low(operand_low),
      .halted(halted), .opcode(opcode), .immediate(immediate),
      .tx_pop(tx_pop), .rx_push(rx_push),
      .crc_setup(crc_setup), .crc_setup32(crc_setup32),
      .crc_feed(crc_feed), .crc_finalize(crc_finalize),
      .crc_push_lo(crc_push_lo), .crc_push_hi(crc_push_hi),
      .crc_push_b2(crc_push_b2), .crc_push_b3(crc_push_b3),
      .execute_map(execute_map),
      .execute_shift_out(execute_shift_out),
      .execute_shift_in(execute_shift_in),
      .execute_shift_clear(execute_shift_clear),
      .action_wr_lo(action_wr_lo), .action_wr_hi(action_wr_hi),
      .action_wr_lane_lo(action_wr_lane_lo),
      .action_wr_lane_hi(action_wr_lane_hi),
      .action_start(action_start),
      .action_load_shift(action_load_shift),
      .action_load_shift_hi(action_load_shift_hi),
      .action_load_tx(action_load_tx),
      .action_read_result(action_read_result),
      .action_push_result(action_push_result)
  );

  reg past_valid = 1'b0;
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    past_valid <= 1'b1;
    if (rst_n) begin
      if (action_busy) begin
        // A live region owns both FIFO ports, CRC, the shared shifter,
        // action table, result, and physical pin map.
        assert(!tx_pop && !rx_push);
        assert(!crc_setup && !crc_setup32 && !crc_feed && !crc_finalize);
        assert(!crc_push_lo && !crc_push_hi && !crc_push_b2 && !crc_push_b3);
        assert(!execute_map && !execute_shift_out && !execute_shift_in &&
               !execute_shift_clear);
        assert(!action_wr_lo && !action_wr_hi &&
               !action_wr_lane_lo && !action_wr_lane_hi);
        assert(!action_load_shift && !action_load_shift_hi && !action_load_tx);
        assert(!action_start && !action_read_result && !action_push_result);
      end
      if (past_valid && $past(rst_n && cpu_pin_conflict && state == 4'd3)) begin
        assert(state == 4'd3);
        assert(program_counter == $past(program_counter));
      end
      // NOP is an unconditional, non-environment-stalled instruction.
      if (past_valid && $past(rst_n && state == 4'd3 &&
                              opcode == 4'h0 && immediate == 4'h0 &&
                              !cpu_pin_conflict)) begin
        assert(state == 4'd1);
        assert(program_counter == $past(program_counter) + 1'b1);
      end
      // Branch polarity is checked against the sampled ALU zero flag, not
      // against the sequencer's own branch_taken combinational expression.
      if (past_valid && $past(rst_n && state == 4'd7 &&
                              opcode == 4'h8 && immediate == 4'h1)) begin
        assert(state == 4'd1);
        assert(program_counter == ($past(alu_zero) ?
            {$past(instruction_data[1:0]), $past(operand_low)} :
            ($past(program_counter) + 1'b1)));
      end
      if (past_valid && $past(rst_n && state == 4'd7 &&
                              opcode == 4'h8 && immediate == 4'h2)) begin
        assert(state == 4'd1);
        assert(program_counter == (!$past(alu_zero) ?
            {$past(instruction_data[1:0]), $past(operand_low)} :
            ($past(program_counter) + 1'b1)));
      end
      cover(action_busy && state == 4'd3 && opcode == 4'ha);
      cover(cpu_pin_conflict && state == 4'd3);
    end
  end
  wire _unused = &{halted, 1'b0};
endmodule

`default_nettype wire
