`default_nettype none

// One cycle-exact execution lane. Each lane owns its program, shifters,
// counter, delay timer, sample latch, and CRC/LFSR state. The primary action
// and the upper side-set bundle execute atomically on the accepting cycle.
module action_lane (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        wr_lo,
    input  wire        wr_hi,
    input  wire        wr_bundle_lo,
    input  wire        wr_bundle_hi,
    input  wire [3:0]  wr_slot,
    input  wire [7:0]  wr_data,
    input  wire        load_shift_lo,
    input  wire        load_shift_hi,
    input  wire        load_tx,
    input  wire [7:0]  load_data,
    input  wire [4:0]  load_bits,
    input  wire        load_msb_first,
    input  wire        start,
    input  wire [3:0]  start_slot,
    input  wire [7:0]  repeat_count,
    input  wire [7:0]  pin_sampled,
    input  wire [7:0]  pin_timed,
    output wire        tx_request,
    input  wire        tx_grant,
    input  wire [7:0]  tx_data,
    output wire        rx_request,
    input  wire        rx_grant,
    output wire [7:0]  rx_data,
    output wire        busy,
    output wire        table_ready,
    output reg         done_pulse,
    output wire [15:0] result,
    output wire [15:0] lfsr_value,
    output wire [7:0]  launch_claim,
    output wire        drive_enable,
    output wire [7:0]  drive_out_value,
    output wire [7:0]  drive_out_mask,
    output wire [7:0]  drive_oe_value,
    output wire [7:0]  drive_oe_mask,
    output wire [7:0]  claim
);
  localparam OP_NOP    = 4'h0;
  localparam OP_GPIO   = 4'h1;
  localparam OP_SAMPLE = 4'h2;
  localparam OP_SHIFT  = 4'h3;
  localparam OP_COUNT  = 4'h4;
  localparam OP_LFSR   = 4'h5;
  localparam OP_NEXT   = 4'h6;
  localparam OP_DELAY  = 4'h7;
  localparam OP_REPEAT = 4'h8;
  localparam OP_DONE   = 4'h9;
  localparam OP_PAIR   = 4'ha;
  localparam OP_PULL   = 4'hb;
  localparam OP_PUSH   = 4'hc;

  localparam CNT_LOAD = 2'b00;
  localparam CNT_INC  = 2'b01;
  localparam CNT_DEC  = 2'b10;
  localparam CNT_DJNZ = 2'b11;

  localparam ST_IDLE  = 2'd0;
  localparam ST_RUN   = 2'd1;
  localparam ST_DELAY = 2'd2;

  reg [31:0] slots [0:15];
  reg [15:0] slot_valid;
  reg [15:0] slot_ready;
  reg [1:0] state;
  reg [3:0] pc;
  reg [3:0] base_slot;
  reg [7:0] repeats_left;
  reg [15:0] delay_counter;
  reg [15:0] counter;
  reg [15:0] tx_shift;
  reg [15:0] rx_shift;
  reg [15:0] result_r;
  reg [15:0] lfsr;
  reg [15:0] lfsr_poly;
  reg [2:0] stream_bit;
  reg sample_bit;
  reg [7:0] reserved_claim;

  reg drive_active;
  reg [7:0] out_value;
  reg [7:0] out_mask;
  reg [7:0] oe_value;
  reg [7:0] oe_mask;
  reg [7:0] bundle_out_value;
  reg [7:0] bundle_out_mask;
  reg [7:0] bundle_oe_value;
  reg [7:0] bundle_oe_mask;

  wire [31:0] current = slots[pc];
  wire [15:0] bundle = current[31:16];
  wire [3:0] op = current[15:12];
  wire [11:0] args = current[11:0];
  wire [2:0] pin = args[2:0];
  wire [7:0] pin_mask = 8'b1 << pin;
  wire [7:0] bundle_mask = 8'b1 << bundle[10:8];
  wire tx_bit = args[10] ? tx_shift[15] : tx_shift[0];
  wire rx_bit = args[11] ? pin_timed[pin] : pin_timed[args[6:4]];
  wire stream_shift = op == OP_SHIFT && args[7];
  wire shift_reads = args[11] || args[9];
  wire stream_tx_start = stream_shift && !args[11] && stream_bit == 0;
  wire stream_rx_done = stream_shift && shift_reads && stream_bit == 7;
  wire shift_tx_bit = stream_tx_start ?
      (args[10] ? tx_data[7] : tx_data[0]) : tx_bit;
  wire [15:0] rx_shift_next = args[10] ?
      {rx_shift[14:0], rx_bit} : {rx_bit, rx_shift[15:1]};
  wire action_accept = (!tx_request || tx_grant) &&
                       (!rx_request || rx_grant);

  // Bundle fields: enable, oe_we, oe, out_we, out, pin[2:0], sample,
  // LFSR update, counter decrement, post-delay[4:0].
  wire bundle_exec = bundle[15] && action_accept;
  wire bundle_delay_ok = op != OP_DELAY && op != OP_NEXT &&
      op != OP_REPEAT && op != OP_DONE &&
      !(op == OP_COUNT && args[11:10] == CNT_DJNZ);

  function [15:0] lfsr_step;
    input [15:0] value;
    input [15:0] polynomial;
    input data_bit;
    reg feedback;
    begin
      feedback = value[15] ^ data_bit;
      lfsr_step = {value[14:0], 1'b0} ^
                  (feedback ? polynomial : 16'b0);
    end
  endfunction

  reg [7:0] claim_scan;
  reg [31:0] scan_word;
  integer scan_index;
  always @(*) begin
    claim_scan = 8'b0;
    scan_word = 32'b0;
    for (scan_index = 0; scan_index < 16; scan_index = scan_index + 1) begin
      scan_word = slots[scan_index];
      if (slot_valid[scan_index]) begin
        if (scan_word[31] &&
            (scan_word[30] || scan_word[28] ||
             (scan_word[23] && scan_word[15:12] != OP_SAMPLE &&
                              scan_word[15:12] != OP_SHIFT) ||
             (scan_word[22] && scan_word[15:12] != OP_SHIFT)))
          claim_scan[scan_word[26:24]] = 1'b1;
        case (scan_word[15:12])
          OP_GPIO, OP_SAMPLE:
            claim_scan[scan_word[2:0]] = 1'b1;
          OP_SHIFT: begin
            claim_scan[scan_word[2:0]] = 1'b1;
            if (scan_word[9])
              claim_scan[scan_word[6:4]] = 1'b1;
          end
          OP_PAIR: begin
            claim_scan[scan_word[2:0]] = 1'b1;
            claim_scan[scan_word[5:3]] = 1'b1;
          end
          OP_DELAY:
            if (scan_word[11]) claim_scan[scan_word[10:8]] = 1'b1;
          default: begin end
        endcase
      end
    end
  end

  assign busy = state != ST_IDLE;
  assign table_ready = ~|(slot_valid & ~slot_ready);
  assign result = result_r;
  assign lfsr_value = lfsr;
  assign launch_claim = claim_scan;
  assign claim = reserved_claim;
  assign drive_enable = drive_active;
  assign drive_out_value = (out_value & ~bundle_out_mask) |
                           (bundle_out_value & bundle_out_mask);
  assign drive_out_mask = out_mask | bundle_out_mask;
  assign drive_oe_value = (oe_value & ~bundle_oe_mask) |
                          (bundle_oe_value & bundle_oe_mask);
  assign drive_oe_mask = oe_mask | bundle_oe_mask;
  assign tx_request = state == ST_RUN &&
                      (op == OP_PULL || stream_tx_start);
  assign rx_request = state == ST_RUN &&
                      (op == OP_PUSH || stream_rx_done);
  assign rx_data = stream_rx_done ?
      (args[10] ? rx_shift_next[7:0] : rx_shift_next[15:8]) :
      ((args[0] ? rx_shift[15:8] : rx_shift[7:0]) << args[4:1]);

  integer slot_index;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (slot_index = 0; slot_index < 16; slot_index = slot_index + 1)
        slots[slot_index] <= 32'b0;
      slot_valid <= 16'b0;
      slot_ready <= 16'b0;
      state <= ST_IDLE;
      pc <= 4'b0;
      base_slot <= 4'b0;
      repeats_left <= 8'b0;
      delay_counter <= 16'b0;
      counter <= 16'b0;
      tx_shift <= 16'b0;
      rx_shift <= 16'b0;
      result_r <= 16'b0;
      lfsr <= 16'hffff;
      lfsr_poly <= 16'h1021;
      stream_bit <= 3'b0;
      sample_bit <= 1'b0;
      reserved_claim <= 8'b0;
      drive_active <= 1'b0;
      out_value <= 8'b0;
      out_mask <= 8'b0;
      oe_value <= 8'b0;
      oe_mask <= 8'b0;
      bundle_out_value <= 8'b0;
      bundle_out_mask <= 8'b0;
      bundle_oe_value <= 8'b0;
      bundle_oe_mask <= 8'b0;
      done_pulse <= 1'b0;
    end else if (!enable) begin
      state <= ST_IDLE;
      reserved_claim <= 8'b0;
      drive_active <= 1'b0;
      out_mask <= 8'b0;
      oe_mask <= 8'b0;
      bundle_out_mask <= 8'b0;
      bundle_oe_mask <= 8'b0;
      done_pulse <= 1'b0;
    end else begin
      done_pulse <= 1'b0;

      if (wr_lo && state == ST_IDLE) begin
        slots[wr_slot][7:0] <= wr_data;
        slots[wr_slot][31:16] <= 16'b0;
        if (wr_slot == 4'b0)
          slot_valid <= 16'b1;
        else
          slot_valid[wr_slot] <= 1'b1;
        slot_ready[wr_slot] <= 1'b0;
      end
      if (wr_hi && state == ST_IDLE) begin
        slots[wr_slot][15:8] <= wr_data;
        slot_ready[wr_slot] <= 1'b1;
      end
      if (wr_bundle_lo && state == ST_IDLE) begin
        slots[wr_slot][23:16] <= wr_data;
        slot_ready[wr_slot] <= 1'b0;
      end
      if (wr_bundle_hi && state == ST_IDLE) begin
        slots[wr_slot][31:24] <= wr_data;
        slot_ready[wr_slot] <= 1'b1;
      end
      if (load_shift_lo && state == ST_IDLE)
        tx_shift[7:0] <= load_data;
      if (load_shift_hi && state == ST_IDLE)
        tx_shift[15:8] <= load_data;
      if (load_tx && state == ST_IDLE)
        tx_shift <= load_msb_first ?
            ({8'b0, load_data} << (5'd16 - load_bits)) : {8'b0, load_data};

      if (start && state == ST_IDLE && table_ready) begin
        state <= ST_RUN;
        pc <= start_slot;
        base_slot <= start_slot;
        repeats_left <= repeat_count;
        delay_counter <= 16'b0;
        rx_shift <= 16'b0;
        result_r <= 16'b0;
        stream_bit <= 3'b0;
        reserved_claim <= claim_scan;
        drive_active <= 1'b0;
        out_mask <= 8'b0;
        oe_mask <= 8'b0;
        bundle_out_mask <= 8'b0;
        bundle_oe_mask <= 8'b0;
      end else begin
        case (state)
          ST_DELAY: begin
            if (delay_counter == 16'b0 &&
                (!args[11] || pin_sampled[args[10:8]])) begin
              state <= ST_RUN;
              pc <= pc + 1'b1;
            end else if (delay_counter != 16'b0)
              delay_counter <= delay_counter - 1'b1;
          end

          ST_RUN: begin
            if (bundle_exec) begin
              drive_active <= 1'b1;
              if (bundle[12]) begin
                bundle_out_mask <= bundle_out_mask | bundle_mask;
                if (bundle[11])
                  bundle_out_value <= bundle_out_value | bundle_mask;
                else
                  bundle_out_value <= bundle_out_value & ~bundle_mask;
              end
              if (bundle[14]) begin
                bundle_oe_mask <= bundle_oe_mask | bundle_mask;
                if (bundle[13])
                  bundle_oe_value <= bundle_oe_value | bundle_mask;
                else
                  bundle_oe_value <= bundle_oe_value & ~bundle_mask;
              end
              if (bundle[7] && op != OP_SAMPLE && op != OP_SHIFT) begin
                sample_bit <= pin_timed[bundle[10:8]];
                result_r <= {15'b0, pin_timed[bundle[10:8]]};
              end
              if (bundle[6])
                lfsr <= lfsr_step(lfsr, lfsr_poly,
                    op == OP_SHIFT ?
                    (shift_reads ? rx_bit : shift_tx_bit) :
                    pin_timed[bundle[10:8]]);
              if (bundle[5])
                counter <= counter - 1'b1;
            end

            if (action_accept) begin
              case (op)
                OP_NOP: pc <= pc + 1'b1;

                OP_GPIO: begin
                  drive_active <= 1'b1;
                  if (args[9]) begin
                    out_mask <= out_mask | pin_mask;
                    if (args[8]) out_value <= out_value | pin_mask;
                    else out_value <= out_value & ~pin_mask;
                  end
                  if (args[11]) begin
                    oe_mask <= oe_mask | pin_mask;
                    if (args[10]) oe_value <= oe_value | pin_mask;
                    else oe_value <= oe_value & ~pin_mask;
                  end
                  pc <= pc + 1'b1;
                end

                OP_SAMPLE: begin
                  sample_bit <= pin_timed[pin];
                  if (args[11])
                    result_r <= args[10] ?
                        {result_r[14:0], pin_timed[pin]} :
                        {pin_timed[pin], result_r[15:1]};
                  else
                    result_r <= {15'b0, pin_timed[pin]};
                  pc <= pc + 1'b1;
                end

                OP_SHIFT: begin
                  // Separate shifters make TX and RX update concurrently.
                  sample_bit <= rx_bit;
                  if (shift_reads) begin
                    rx_shift <= rx_shift_next;
                    result_r <= rx_shift_next;
                  end
                  if (!args[11]) begin
                    drive_active <= 1'b1;
                    out_mask <= out_mask | pin_mask;
                    oe_mask <= oe_mask | pin_mask;
                    if (args[8]) begin
                      out_value <= out_value & ~pin_mask;
                      if (shift_tx_bit) oe_value <= oe_value & ~pin_mask;
                      else oe_value <= oe_value | pin_mask;
                    end else begin
                      if (shift_tx_bit) out_value <= out_value | pin_mask;
                      else out_value <= out_value & ~pin_mask;
                      oe_value <= oe_value | pin_mask;
                    end
                    if (stream_tx_start)
                      tx_shift <= args[10] ? {tx_data[6:0], 9'b0} :
                                            {9'b0, tx_data[7:1]};
                    else if (args[10])
                      tx_shift <= {tx_shift[14:0], 1'b0};
                    else
                      tx_shift <= {1'b0, tx_shift[15:1]};
                  end
                  if (stream_shift)
                    stream_bit <= stream_bit + 1'b1;
                  pc <= pc + 1'b1;
                end

                OP_COUNT: begin
                  case (args[11:10])
                    CNT_LOAD: begin counter <= {8'b0, args[7:0]}; pc <= pc + 1'b1; end
                    CNT_INC: begin counter <= counter + 1'b1; pc <= pc + 1'b1; end
                    CNT_DEC: begin counter <= counter - 1'b1; pc <= pc + 1'b1; end
                    default: begin
                      if (counter != 16'd1) begin
                        counter <= counter - 1'b1;
                        pc <= args[3:0];
                      end else begin
                        counter <= 16'b0;
                        if (args[9]) begin
                          done_pulse <= 1'b1;
                          state <= ST_IDLE;
                          reserved_claim <= 8'b0;
                          drive_active <= 1'b0;
                          out_mask <= 8'b0;
                          oe_mask <= 8'b0;
                          bundle_out_mask <= 8'b0;
                          bundle_oe_mask <= 8'b0;
                        end else
                          pc <= pc + 1'b1;
                      end
                    end
                  endcase
                end

                OP_LFSR: begin
                  case (args[11:10])
                    2'b00: lfsr <= lfsr_step(lfsr, lfsr_poly, tx_shift[0]);
                    2'b01: begin
                      if (args[9]) lfsr_poly[15:8] <= args[7:0];
                      else lfsr_poly[7:0] <= args[7:0];
                    end
                    2'b10: begin
                      if (args[9]) lfsr[15:8] <= args[7:0];
                      else lfsr[7:0] <= args[7:0];
                    end
                    default: result_r <= lfsr;
                  endcase
                  pc <= pc + 1'b1;
                end

                OP_NEXT: begin
                  case (args[11:8])
                    4'h0: pc <= args[3:0];
                    4'h1: pc <= counter == 0 ? args[3:0] : pc + 1'b1;
                    4'h2: pc <= counter != 0 ? args[3:0] : pc + 1'b1;
                    4'h3: pc <= sample_bit ? args[3:0] : pc + 1'b1;
                    4'h4: pc <= !sample_bit ? args[3:0] : pc + 1'b1;
                    default: pc <= pc + 1'b1;
                  endcase
                end

                OP_DELAY: begin
                  if (args[7:0] == 0 &&
                      (!args[11] || pin_sampled[args[10:8]]))
                    pc <= pc + 1'b1;
                  else begin
                    delay_counter <= args[7:0] == 0 ? 16'b0 :
                                     {8'b0, args[7:0]} - 16'd1;
                    state <= ST_DELAY;
                  end
                end

                OP_REPEAT: pc <= args[3:0];

                OP_PAIR: begin
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
                  tx_shift <= args[5] ?
                      ({8'b0, tx_data} << (5'd16 -
                       (args[4:0] == 0 ? 5'd16 : args[4:0]))) :
                      {8'b0, tx_data};
                  pc <= pc + 1'b1;
                end

                OP_PUSH: pc <= pc + 1'b1;

                OP_DONE: begin
                  drive_active <= 1'b0;
                  out_mask <= 8'b0;
                  oe_mask <= 8'b0;
                  bundle_out_mask <= 8'b0;
                  bundle_oe_mask <= 8'b0;
                  if (repeats_left != 0) begin
                    repeats_left <= repeats_left - 1'b1;
                    pc <= base_slot;
                  end else begin
                    done_pulse <= 1'b1;
                    state <= ST_IDLE;
                    reserved_claim <= 8'b0;
                  end
                end

                default: pc <= pc + 1'b1;
              endcase

              if (bundle_exec && bundle_delay_ok && bundle[4:0] != 0) begin
                delay_counter <= {11'b0, bundle[4:0]} - 1'b1;
                state <= ST_DELAY;
              end
            end
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
  end
endmodule

`default_nettype wire
