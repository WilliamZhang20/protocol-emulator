`default_nettype none

// Tiny programmable action engine: 8 slots, one action per cycle with a parallel pin lane.
// Shared shift/counter/result datapaths are steered by action words; GPIO,
// sample, CRC update, conditional next, delay/repeat, and done/event cover
// the shared primitive set. Protocol waveforms are action programs.
module action_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // Program action table (32-bit words; upper lane acts in parallel)
    input  wire        wr_lo,
    input  wire        wr_hi,
    input  wire        wr_lane_lo,
    input  wire        wr_lane_hi,
    input  wire [2:0]  wr_slot,
    input  wire [7:0]  wr_data,

    // Optional shift preload (e.g. host/TX byte)
    input  wire        load_shift,
    input  wire        load_shift_hi,
    input  wire        load_tx,
    input  wire [7:0]  tx_data,
    input  wire        tx_empty,
    output wire       tx_pop,
    input  wire        rx_full,
    output wire       rx_push,
    output wire [7:0] rx_data,
    input  wire [4:0]  tx_bits,
    input  wire        tx_msb_first,
    input  wire [7:0]  shift_data,
    input  wire        manual_load,
    input  wire [7:0]  manual_data,
    input  wire        manual_shift,
    input  wire        manual_serial_in,
    output wire        manual_serial_out,
    output wire [15:0] shift_parallel,

    // Run control
    input  wire        start,
    input  wire [2:0]  start_slot,
    input  wire [7:0]  repeat_count,  // extra passes after first; 0 = once

    input  wire [7:0]  pin_sampled,
    input  wire [7:0]  pin_timed,

    input  wire        crc_busy,
    output wire        crc_feed,
    output wire [7:0]  crc_byte,

    output wire        busy,
    output wire        table_ready,
    output wire        done_pulse,
    output wire [15:0] result,

    output wire        drive_enable,
    output wire [7:0]  drive_out_value,
    output wire [7:0]  drive_out_mask,
    output wire [7:0]  drive_oe_value,
    output wire [7:0]  drive_oe_mask,
    output wire [7:0]  claim
);
  // Action opcodes in word[15:12]
  localparam OP_NOP    = 4'h0;
  localparam OP_GPIO   = 4'h1;
  localparam OP_SAMPLE = 4'h2;
  localparam OP_SHIFT  = 4'h3;
  localparam OP_COUNT  = 4'h4;
  localparam OP_CRC    = 4'h5;
  localparam OP_NEXT   = 4'h6;
  localparam OP_DELAY  = 4'h7;
  localparam OP_REPEAT = 4'h8;
  localparam OP_DONE   = 4'h9;
  localparam OP_PAIR   = 4'ha;
  localparam OP_PULL   = 4'hb;
  localparam OP_PUSH   = 4'hc;

  // OP_COUNT modes in word[11:10]
  localparam CNT_LOAD  = 2'b00;
  localparam CNT_INC   = 2'b01;
  localparam CNT_DEC   = 2'b10;
  localparam CNT_DJNZ  = 2'b11;

  // OP_NEXT conditions in word[11:8]
  localparam COND_ALWAYS     = 4'h0;
  localparam COND_CTR_ZERO   = 4'h1;
  localparam COND_CTR_NZERO  = 4'h2;
  localparam COND_SAMPLE_1   = 4'h3;
  localparam COND_SAMPLE_0   = 4'h4;

  localparam ST_IDLE  = 2'd0;
  localparam ST_RUN   = 2'd1;
  localparam ST_DELAY = 2'd2;

  reg [31:0] slots [0:7];
  reg [7:0] slot_valid;
  reg [7:0] slot_ready;
  reg [7:0] reserved_claim;
  reg [1:0]  state;
  reg [2:0]  pc;
  reg [2:0]  base_slot;
  reg [7:0]  repeats_left;
  reg [7:0]  delay_ctr;
  reg [7:0]  counter;
  reg [15:0] shift_reg;
  reg [15:0] result_r;
  reg        sample_bit;
  reg        done_r;
  reg        crc_feed_r;
  reg        crc_pending;
  reg [7:0]  crc_byte_r;
  reg [1:0]  crc_issue;

  reg        drv_en;
  reg [7:0]  drv_out;
  reg [7:0]  drv_out_m;
  reg [7:0]  drv_oe;
  reg [7:0]  drv_oe_m;
  reg [7:0]  claim_r;
  reg [7:0]  lane_out;
  reg [7:0]  lane_out_m;
  reg [7:0]  lane_oe;
  reg [7:0]  lane_oe_m;
  reg [7:0]  lane_claim;

  wire [31:0] cur = slots[pc];
  wire [15:0] lane = cur[31:16];
  wire [7:0] lane_mask = 8'b1 << lane[10:8];
  wire lane_level = pin_timed[lane[10:8]];
  wire [3:0]  op = cur[15:12];
  wire [11:0] args = cur[11:0];
  wire [2:0]  arg_pin = args[2:0];
  wire [7:0]  pin_mask = 8'b1 << arg_pin;
  wire        timed_pin_level = pin_timed[arg_pin];
  wire        timed_rx_level = pin_timed[args[6:4]];
  wire action_accept =
      !(op == OP_PULL && tx_empty) &&
      !(op == OP_PUSH && rx_full) &&
      !(op == OP_CRC && crc_pending) &&
      !(op == OP_DONE && crc_pending) &&
      !(op == OP_COUNT && args[11:10] == CNT_DJNZ &&
        counter == 8'd1 && args[9] && crc_pending);

  // The complete region claim is computed before launch. Slot 0 starts a
  // fresh table generation, so stale slots from the previous region do not
  // acquire pins. Input pins are reserved too: CPU writes cannot disturb an
  // active sampled bus.
  reg [7:0] launch_claim;
  integer ci;
  reg [31:0] claim_word;
  always @(*) begin
    launch_claim = 8'b0;
    claim_word = 32'b0;
    for (ci = 0; ci < 8; ci = ci + 1) begin
      claim_word = slots[ci];
      if (slot_valid[ci]) begin
        if (claim_word[31])
          launch_claim[claim_word[26:24]] = 1'b1;
        case (claim_word[15:12])
          OP_GPIO, OP_SAMPLE, OP_SHIFT:
            launch_claim[claim_word[2:0]] = 1'b1;
          OP_PAIR: begin
            launch_claim[claim_word[2:0]] = 1'b1;
            launch_claim[claim_word[5:3]] = 1'b1;
          end
          OP_DELAY:
            if (claim_word[11]) launch_claim[claim_word[10:8]] = 1'b1;
          default: begin end
        endcase
        if (claim_word[15:12] == OP_SHIFT && claim_word[9])
          launch_claim[claim_word[6:4]] = 1'b1;
      end
    end
  end

  assign busy = state != ST_IDLE;
  assign table_ready = ~|(slot_valid & ~slot_ready);
  assign done_pulse = done_r;
  assign result = result_r;
  assign crc_feed = crc_feed_r;
  assign crc_byte = crc_byte_r;
  assign manual_serial_out = shift_reg[0];
  assign shift_parallel = shift_reg;
  assign drive_enable = drv_en;
  assign drive_out_value = (drv_out & ~lane_out_m) | (lane_out & lane_out_m);
  assign drive_out_mask = drv_out_m | lane_out_m;
  assign drive_oe_value = (drv_oe & ~lane_oe_m) | (lane_oe & lane_oe_m);
  assign drive_oe_mask = drv_oe_m | lane_oe_m;
  assign claim = reserved_claim;
  assign tx_pop = state == ST_RUN && op == OP_PULL && !tx_empty;
  assign rx_push = state == ST_RUN && op == OP_PUSH && !rx_full;
  assign rx_data = (args[0] ? result_r[15:8] : result_r[7:0]) << args[4:1];

  integer si;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (si = 0; si < 8; si = si + 1)
        slots[si] <= 32'b0;
      state <= ST_IDLE;
      slot_valid <= 8'b0;
      slot_ready <= 8'b0;
      reserved_claim <= 8'b0;
      pc <= 3'b0;
      base_slot <= 3'b0;
      repeats_left <= 8'b0;
      delay_ctr <= 8'b0;
      counter <= 8'b0;
      shift_reg <= 16'b0;
      result_r <= 16'b0;
      sample_bit <= 1'b0;
      done_r <= 1'b0;
      crc_feed_r <= 1'b0;
      crc_pending <= 1'b0;
      crc_byte_r <= 8'b0;
      crc_issue <= 2'b0;
      drv_en <= 1'b0;
      drv_out <= 8'b0;
      drv_out_m <= 8'b0;
      drv_oe <= 8'b0;
      drv_oe_m <= 8'b0;
      claim_r <= 8'b0;
      lane_out <= 8'b0;
      lane_out_m <= 8'b0;
      lane_oe <= 8'b0;
      lane_oe_m <= 8'b0;
      lane_claim <= 8'b0;
    end else if (!enable) begin
      state <= ST_IDLE;
      reserved_claim <= 8'b0;
      done_r <= 1'b0;
      crc_feed_r <= 1'b0;
      crc_pending <= 1'b0;
      crc_issue <= 2'b0;
      drv_en <= 1'b0;
      drv_out_m <= 8'b0;
      drv_oe_m <= 8'b0;
      claim_r <= 8'b0;
      lane_out <= 8'b0;
      lane_out_m <= 8'b0;
      lane_oe <= 8'b0;
      lane_oe_m <= 8'b0;
      lane_claim <= 8'b0;
    end else begin
      done_r <= 1'b0;
      crc_feed_r <= 1'b0;

      // One-entry CRC issue queue. The action PC can advance immediately
      // after enqueue; the queue waits for the shared CRC datapath and is
      // drained before region completion.
      if (crc_pending) begin
        if (crc_issue == 2'd0 && !crc_busy) begin
          crc_feed_r <= 1'b1;
          crc_issue <= 2'd1;
        end else if (crc_issue == 2'd1 && crc_busy) begin
          crc_issue <= 2'd2;
        end else if (crc_issue == 2'd2 && !crc_busy) begin
          crc_issue <= 2'd0;
          crc_pending <= 1'b0;
        end
      end

      if (wr_lo && state == ST_IDLE) begin
        slots[wr_slot][7:0] <= wr_data;
        // A low-byte rewrite starts a fresh word with no upper lane.
        slots[wr_slot][31:16] <= 16'b0;
        if (wr_slot == 3'd0) slot_valid <= 8'b1;
        else slot_valid[wr_slot] <= 1'b1;
        slot_ready[wr_slot] <= 1'b0;
      end
      if (wr_hi && state == ST_IDLE) begin
        slots[wr_slot][15:8] <= wr_data;
        slot_ready[wr_slot] <= 1'b1;
      end
      if (wr_lane_lo && state == ST_IDLE) begin
        slots[wr_slot][23:16] <= wr_data;
        slot_ready[wr_slot] <= 1'b0;
      end
      if (wr_lane_hi && state == ST_IDLE) begin
        slots[wr_slot][31:24] <= wr_data;
        slot_ready[wr_slot] <= 1'b1;
      end
      if (load_shift && state == ST_IDLE)
        shift_reg[7:0] <= shift_data;
      if (load_shift_hi && state == ST_IDLE)
        shift_reg[15:8] <= shift_data;
      if (load_tx && state == ST_IDLE)
        shift_reg <= tx_msb_first ? ({8'b0, tx_data} << (5'd16 - tx_bits)) :
                     {8'b0, tx_data};
      if (manual_load && state == ST_IDLE)
        shift_reg <= {8'b0, manual_data};
      else if (manual_shift && state == ST_IDLE)
        shift_reg <= {manual_serial_in, shift_reg[15:1]};

      if (start && state == ST_IDLE && table_ready) begin
        state <= ST_RUN;
        reserved_claim <= launch_claim;
        pc <= start_slot;
        base_slot <= start_slot;
        repeats_left <= repeat_count;
        result_r <= 16'b0;
        delay_ctr <= 8'b0;
        drv_en <= 1'b0;
        drv_out_m <= 8'b0;
        drv_oe_m <= 8'b0;
        claim_r <= 8'b0;
        lane_out <= 8'b0;
        lane_out_m <= 8'b0;
        lane_oe <= 8'b0;
        lane_oe_m <= 8'b0;
        lane_claim <= 8'b0;
      end else begin
        case (state)
          ST_DELAY: begin
            if (delay_ctr == 8'd0 &&
                (!args[11] || pin_sampled[args[10:8]])) begin
              state <= ST_RUN;
              pc <= pc + 1'b1;
            end else
              delay_ctr <= delay_ctr - 1'b1;
          end
          ST_RUN: begin
            // Upper lane: independent GPIO update and optional sample. A
            // lane can change a clock while the primary SHIFT/SAMPLE runs.
            // The lane is suppressed during CRC stalls to issue once only.
            if (lane[15] && op != OP_CRC && action_accept) begin
              drv_en <= 1'b1;
              lane_claim <= lane_claim | lane_mask;
              if (lane[12]) begin
                lane_out_m <= lane_out_m | lane_mask;
                if (lane[11])
                  lane_out <= lane_out | lane_mask;
                else
                  lane_out <= lane_out & ~lane_mask;
              end
              if (lane[14]) begin
                lane_oe_m <= lane_oe_m | lane_mask;
                if (lane[13])
                  lane_oe <= lane_oe | lane_mask;
                else
                  lane_oe <= lane_oe & ~lane_mask;
              end
              if (lane[7] && op != OP_SAMPLE && op != OP_SHIFT) begin
                sample_bit <= lane_level;
                result_r <= {15'b0, lane_level};
              end
            end
            case (op)
              OP_NOP: pc <= pc + 1'b1;

              OP_GPIO: begin
                // args: [11]=oe_we, [10]=oe_val, [9]=out_we, [8]=out_val, [2:0]=pin
                drv_en <= 1'b1;
                claim_r <= claim_r | pin_mask;
                if (args[9]) begin
                  drv_out_m <= drv_out_m | pin_mask;
                  if (args[8])
                    drv_out <= drv_out | pin_mask;
                  else
                    drv_out <= drv_out & ~pin_mask;
                end
                if (args[11]) begin
                  drv_oe_m <= drv_oe_m | pin_mask;
                  if (args[10])
                    drv_oe <= drv_oe | pin_mask;
                  else
                    drv_oe <= drv_oe & ~pin_mask;
                end
                pc <= pc + 1'b1;
              end

              OP_SAMPLE: begin
                sample_bit <= timed_pin_level;
                if (args[11])
                  result_r <= args[10] ? {result_r[14:0], timed_pin_level} :
                      {timed_pin_level, result_r[15:1]};
                else
                  result_r <= {15'b0, timed_pin_level};
                pc <= pc + 1'b1;
              end

              OP_SHIFT: begin
                // args: [11]=in (else out), [10]=msb_first,
                // [9]=duplex RX, [8]=open-drain TX, [6:4]=RX pin,
                // [2:0]=TX pin.
                drv_en <= 1'b1;
                claim_r <= claim_r | pin_mask;
                if (args[11]) begin
                  // shift in
                  if (args[10])
                    shift_reg <= {shift_reg[14:0], timed_pin_level};
                  else
                    shift_reg <= {timed_pin_level, shift_reg[15:1]};
                  result_r <= args[10] ?
                      {shift_reg[14:0], timed_pin_level} :
                      {timed_pin_level, shift_reg[15:1]};
                end else begin
                  // shift out: drive then shift
                  drv_out_m <= pin_mask;
                  drv_oe_m <= pin_mask;
                  if (args[10]) begin
                    drv_out <= (!args[8] && shift_reg[15]) ? pin_mask : 8'b0;
                    drv_oe <= (!args[8] || !shift_reg[15]) ? pin_mask : 8'b0;
                    shift_reg <= {shift_reg[14:0], args[9] ? timed_rx_level : 1'b0};
                    if (args[9])
                      result_r <= {shift_reg[14:0], timed_rx_level};
                  end else begin
                    drv_out <= (!args[8] && shift_reg[0]) ? pin_mask : 8'b0;
                    drv_oe <= (!args[8] || !shift_reg[0]) ? pin_mask : 8'b0;
                    shift_reg <= {args[9] ? timed_rx_level : 1'b0, shift_reg[15:1]};
                    if (args[9])
                      result_r <= {timed_rx_level, shift_reg[15:1]};
                  end
                end
                pc <= pc + 1'b1;
              end

              OP_COUNT: begin
                case (args[11:10])
                  CNT_LOAD: begin
                    counter <= args[7:0];
                    pc <= pc + 1'b1;
                  end
                  CNT_INC: begin
                    counter <= counter + 1'b1;
                    pc <= pc + 1'b1;
                  end
                  CNT_DEC: begin
                    counter <= counter - 1'b1;
                    pc <= pc + 1'b1;
                  end
                  default: begin // CNT_DJNZ
                    if (counter != 8'd1) begin
                      counter <= counter - 1'b1;
                      pc <= args[2:0];
                    end else if (!(args[9] && crc_pending)) begin
                      counter <= 8'd0;
                      if (args[9]) begin
                        drv_en <= 1'b0;
                        drv_out_m <= 8'b0;
                        drv_oe_m <= 8'b0;
                        claim_r <= 8'b0;
                        lane_out_m <= 8'b0;
                        lane_oe_m <= 8'b0;
                        lane_claim <= 8'b0;
                        done_r <= 1'b1;
                        state <= ST_IDLE;
                        reserved_claim <= 8'b0;
                      end else
                        pc <= pc + 1'b1;
                    end
                  end
                endcase
              end

              OP_CRC: begin
                if (!crc_pending) begin
                  crc_byte_r <= shift_reg[7:0];
                  crc_pending <= 1'b1;
                  pc <= pc + 1'b1;
                end
              end

              OP_NEXT: begin
                begin : next_cond
                  reg take;
                  case (args[11:8])
                    COND_ALWAYS: take = 1'b1;
                    COND_CTR_ZERO: take = (counter == 8'd0);
                    COND_CTR_NZERO: take = (counter != 8'd0);
                    COND_SAMPLE_1: take = sample_bit;
                    COND_SAMPLE_0: take = ~sample_bit;
                    default: take = 1'b0;
                  endcase
                  if (take)
                    pc <= args[2:0];
                  else
                    pc <= pc + 1'b1;
                end
              end

              OP_DELAY: begin
                if (args[7:0] == 8'd0 &&
                    (!args[11] || pin_sampled[args[10:8]]))
                  pc <= pc + 1'b1;
                else begin
                  delay_ctr <= args[7:0] == 8'd0 ? 8'd0 : args[7:0] - 8'd1;
                  state <= ST_DELAY;
                end
              end

              OP_REPEAT: begin
                // Jump to slot; used for intra-region loops.
                pc <= args[2:0];
              end

              OP_PAIR: begin
                // Decode a two-pin state: SE0=0, J=1, K=2, SE1=3.
                // J is (A=0,B=1) unless args[6] swaps the pair.
                if (!pin_timed[args[2:0]] && !pin_timed[args[5:3]])
                  result_r <= 16'd0;
                else if (pin_timed[args[2:0]] && pin_timed[args[5:3]])
                  result_r <= 16'd3;
                else if (pin_timed[args[2:0]] == args[6])
                  result_r <= 16'd1;
                else
                  result_r <= 16'd2;
                pc <= pc + 1'b1;
              end

              OP_PULL: begin
                // args[4:0]: transfer bits (zero means 16), [5]: MSB first.
                // No PC or shifter update until a TX byte is available.
                if (!tx_empty) begin
                  shift_reg <= args[5] ?
                      ({8'b0, tx_data} << (5'd16 -
                          (args[4:0] == 5'd0 ? 5'd16 : args[4:0]))) :
                      {8'b0, tx_data};
                  pc <= pc + 1'b1;
                end
              end

              OP_PUSH: begin
                // Hold the result and PC until RX has space. The FIFO sees
                // one push on the accepting edge, then execution advances.
                if (!rx_full) pc <= pc + 1'b1;
              end

              OP_DONE: begin
                if (!crc_pending) begin
                  drv_en <= 1'b0;
                  drv_out_m <= 8'b0;
                  drv_oe_m <= 8'b0;
                  claim_r <= 8'b0;
                  lane_out <= 8'b0;
                  lane_out_m <= 8'b0;
                  lane_oe <= 8'b0;
                  lane_oe_m <= 8'b0;
                  lane_claim <= 8'b0;
                  // Leave result_r as last SAMPLE/SHIFT value for READ_RESULT.
                  // Only the final pass posts EV_REGION_DONE.
                  if (repeats_left != 8'd0) begin
                    repeats_left <= repeats_left - 1'b1;
                    pc <= base_slot;
                    state <= ST_RUN;
                  end else begin
                    done_r <= 1'b1;
                    state <= ST_IDLE;
                    reserved_claim <= 8'b0;
                  end
                end
              end

              default: pc <= pc + 1'b1;
            endcase
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
  end
endmodule

`default_nettype wire
