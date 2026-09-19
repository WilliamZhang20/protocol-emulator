`default_nettype none

// Tiny programmable action engine: 8 slots, one action per cycle.
// Shared shift/counter/result datapaths are steered by action words; GPIO,
// sample, CRC update, conditional next, delay/repeat, and done/event cover
// the Phase C primitive set. Protocol-shaped FSMs stay outside this block.
module action_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // Program action table (16-bit words)
    input  wire        wr_lo,
    input  wire        wr_hi,
    input  wire [2:0]  wr_slot,
    input  wire [7:0]  wr_data,

    // Optional shift preload (e.g. host/TX byte)
    input  wire        load_shift,
    input  wire [7:0]  shift_data,

    // Run control
    input  wire        start,
    input  wire [2:0]  start_slot,
    input  wire [7:0]  repeat_count,  // extra passes after first; 0 = once

    input  wire [7:0]  pin_sampled,

    output wire        crc_feed,
    output wire [7:0]  crc_byte,

    output wire        busy,
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

  reg [15:0] slots [0:7];
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

  reg        drv_en;
  reg [7:0]  drv_out;
  reg [7:0]  drv_out_m;
  reg [7:0]  drv_oe;
  reg [7:0]  drv_oe_m;
  reg [7:0]  claim_r;

  wire [15:0] cur = slots[pc];
  wire [3:0]  op = cur[15:12];
  wire [11:0] args = cur[11:0];
  wire [2:0]  arg_pin = args[2:0];
  wire [7:0]  pin_mask = 8'b1 << arg_pin;
  wire        pin_level = pin_sampled[arg_pin];

  assign busy = state != ST_IDLE;
  assign done_pulse = done_r;
  assign result = result_r;
  assign crc_feed = crc_feed_r;
  assign crc_byte = shift_reg[7:0];
  assign drive_enable = drv_en;
  assign drive_out_value = drv_out;
  assign drive_out_mask = drv_out_m;
  assign drive_oe_value = drv_oe;
  assign drive_oe_mask = drv_oe_m;
  assign claim = claim_r;

  integer si;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (si = 0; si < 8; si = si + 1)
        slots[si] <= 16'b0;
      state <= ST_IDLE;
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
      drv_en <= 1'b0;
      drv_out <= 8'b0;
      drv_out_m <= 8'b0;
      drv_oe <= 8'b0;
      drv_oe_m <= 8'b0;
      claim_r <= 8'b0;
    end else if (!enable) begin
      state <= ST_IDLE;
      done_r <= 1'b0;
      crc_feed_r <= 1'b0;
      drv_en <= 1'b0;
      drv_out_m <= 8'b0;
      drv_oe_m <= 8'b0;
      claim_r <= 8'b0;
    end else begin
      done_r <= 1'b0;
      crc_feed_r <= 1'b0;

      if (wr_lo)
        slots[wr_slot][7:0] <= wr_data;
      if (wr_hi)
        slots[wr_slot][15:8] <= wr_data;
      if (load_shift)
        shift_reg[7:0] <= shift_data;

      if (start && state == ST_IDLE) begin
        state <= ST_RUN;
        pc <= start_slot;
        base_slot <= start_slot;
        repeats_left <= repeat_count;
        delay_ctr <= 8'b0;
        drv_en <= 1'b0;
        drv_out_m <= 8'b0;
        drv_oe_m <= 8'b0;
        claim_r <= 8'b0;
      end else begin
        case (state)
          ST_DELAY: begin
            if (delay_ctr == 8'd0) begin
              state <= ST_RUN;
              pc <= pc + 1'b1;
            end else
              delay_ctr <= delay_ctr - 1'b1;
          end
          ST_RUN: begin
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
                sample_bit <= pin_level;
                result_r <= {15'b0, pin_level};
                pc <= pc + 1'b1;
              end

              OP_SHIFT: begin
                // args: [11]=in (else out), [10]=msb_first, [2:0]=pin
                drv_en <= 1'b1;
                claim_r <= claim_r | pin_mask;
                if (args[11]) begin
                  // shift in
                  if (args[10])
                    shift_reg <= {shift_reg[14:0], pin_level};
                  else
                    shift_reg <= {pin_level, shift_reg[15:1]};
                  result_r <= args[10] ?
                      {shift_reg[14:0], pin_level} :
                      {pin_level, shift_reg[15:1]};
                end else begin
                  // shift out: drive then shift
                  drv_out_m <= pin_mask;
                  drv_oe_m <= pin_mask;
                  drv_oe <= pin_mask;
                  if (args[10]) begin
                    drv_out <= shift_reg[15] ? pin_mask : 8'b0;
                    shift_reg <= {shift_reg[14:0], 1'b0};
                  end else begin
                    drv_out <= shift_reg[0] ? pin_mask : 8'b0;
                    shift_reg <= {1'b0, shift_reg[15:1]};
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
                    end else begin
                      counter <= 8'd0;
                      pc <= pc + 1'b1;
                    end
                  end
                endcase
              end

              OP_CRC: begin
                crc_feed_r <= 1'b1;
                pc <= pc + 1'b1;
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
                if (args[7:0] == 8'd0)
                  pc <= pc + 1'b1;
                else begin
                  delay_ctr <= args[7:0] - 8'd1;
                  state <= ST_DELAY;
                end
              end

              OP_REPEAT: begin
                // Jump to slot; used for intra-region loops.
                pc <= args[2:0];
              end

              OP_DONE: begin
                drv_en <= 1'b0;
                drv_out_m <= 8'b0;
                drv_oe_m <= 8'b0;
                claim_r <= 8'b0;
                // Leave result_r as last SAMPLE/SHIFT value for READ_RESULT.
                // Only the final pass posts EV_REGION_DONE so WAIT_REGION
                // joins after RUN_REGION_N completes all repeats.
                if (repeats_left != 8'd0) begin
                  repeats_left <= repeats_left - 1'b1;
                  pc <= base_slot;
                  state <= ST_RUN;
                end else begin
                  done_r <= 1'b1;
                  state <= ST_IDLE;
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
