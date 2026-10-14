`default_nettype none

// One cycle-exact execution lane. Each lane owns a 16-slot action table, TX
// and RX shifters, a counter, a delay timer, a sample bit, and a 16-bit
// LFSR. A slot's primary action and its side-set bundle execute together on
// the cycle the lane accepts the slot.
//
// Slot word:
//   [31:16] bundle  {enable, oe_we, oe, out_we, out, pin[2:0],
//                    sample, lfsr, count_dec, delay[4:0]}
//   [15:12] op
//   [11:0]  args    (per op; see docs/architecture.md)
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

  localparam LFSR_STEP      = 2'b00;
  localparam LFSR_SET_POLY  = 2'b01;
  localparam LFSR_SET_STATE = 2'b10;

  localparam ST_IDLE  = 2'd0;
  localparam ST_RUN   = 2'd1;
  localparam ST_DELAY = 2'd2;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  reg [1:0] state;
  reg [3:0] pc;
  reg [3:0] base_slot;
  reg [7:0] repeats_left;
  reg [7:0] delay_counter;
  reg [15:0] counter;
  reg [15:0] tx_shift;
  reg [15:0] rx_shift;
  reg [15:0] result_r;
  reg [15:0] lfsr;
  reg [15:0] lfsr_poly;
  reg [2:0] stream_bit;
  reg sample_bit;

  // Pin drive. Primary GPIO/SHIFT actions and the bundle side-set keep
  // separate masks; the bundle wins where both drive a pin.
  reg drive_active;
  reg [7:0] out_value;
  reg [7:0] out_mask;
  reg [7:0] oe_value;
  reg [7:0] oe_mask;
  reg [7:0] bundle_out_value;
  reg [7:0] bundle_out_mask;
  reg [7:0] bundle_oe_value;
  reg [7:0] bundle_oe_mask;

  wire idle = state == ST_IDLE;

  // ---------------------------------------------------------------------------
  // Action table
  // ---------------------------------------------------------------------------
  // 16 x 32-bit latch array (see action_slot_byte) with one staged byte-write
  // port and one read port. Latches have no reset; a slot is only observed
  // once marked valid, and invalid slots read as NOP.
  wire [31:0] slots [0:15];
  reg [15:0] slot_valid;
  // A slot is launch-ready once its primary high byte (or bundle high byte)
  // is written; a bundle low byte makes it unready again.
  reg [15:0] slot_ready;
  // Union of the pins claimed by every slot written since the last slot-0
  // low write, accumulated as each slot becomes ready so launch needs no
  // scan. Rewriting a nonzero slot in place can only widen it.
  reg [7:0] table_claim;

  // Write pipeline: stage on the rising edge, hold across the next falling
  // edge, then open the selected byte latches for the following high phase.
  // Latches therefore launch on a rising edge like flops, and the held
  // address and data stay stable for the whole transparent window.
  reg [3:0] stage_slot;
  reg [3:0] stage_bytes;
  reg [7:0] stage_data;
  reg stage_clear;
  // A primary low-byte write also clears the bundle.
  wire [7:0] stage_bundle = stage_clear ? 8'b0 : stage_data;

  reg [3:0] hold_slot;
  reg [3:0] hold_bytes;
  reg [7:0] hold_data;
  reg [7:0] hold_bundle;

  wire table_write = idle &&
      (wr_lo || wr_hi || wr_bundle_lo || wr_bundle_hi);
  // Byte enables {bundle hi, bundle lo, primary hi, primary lo}.
  wire [3:0] write_bytes = {wr_lo || wr_bundle_hi, wr_lo || wr_bundle_lo,
                            wr_hi, wr_lo};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage_slot <= 4'b0;
      stage_bytes <= 4'b0;
      stage_data <= 8'b0;
      stage_clear <= 1'b0;
    end else begin
      stage_bytes <= (enable && table_write) ? write_bytes : 4'b0;
      if (enable && table_write) begin
        stage_slot <= wr_slot;
        stage_data <= wr_data;
        stage_clear <= wr_lo;
      end
    end
  end

  always @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold_slot <= 4'b0;
      hold_bytes <= 4'b0;
      hold_data <= 8'b0;
      hold_bundle <= 8'b0;
    end else begin
      hold_slot <= stage_slot;
      hold_bytes <= stage_bytes;
      hold_data <= stage_data;
      hold_bundle <= stage_bundle;
    end
  end

  genvar slot_index, byte_index;
  generate
    for (slot_index = 0; slot_index < 16; slot_index = slot_index + 1) begin : g_slot
      for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin : g_byte
        action_slot_byte storage (
            .gate(clk && hold_bytes[byte_index] && hold_slot == slot_index),
            .d(byte_index < 2 ? hold_data : hold_bundle),
            .q(slots[slot_index][byte_index * 8 +: 8])
        );
      end
    end
  endgenerate

  // Read port: serves table writes while idle (for the claim update) and
  // instruction fetch while running. A write reaches the latches one cycle
  // after it is accepted; until then the read takes it from the staging
  // register.
  wire [3:0] read_slot = idle ? wr_slot : pc;
  wire [31:0] stored = slots[read_slot];
  wire stage_hit = stage_slot == read_slot;
  wire [31:0] staged = {
      stage_hit && stage_bytes[3] ? stage_bundle : stored[31:24],
      stage_hit && stage_bytes[2] ? stage_bundle : stored[23:16],
      stage_hit && stage_bytes[1] ? stage_data : stored[15:8],
      stage_hit && stage_bytes[0] ? stage_data : stored[7:0]};
  wire [31:0] current = slot_valid[read_slot] ? staged : 32'b0;

  // ---------------------------------------------------------------------------
  // Current slot decode
  // ---------------------------------------------------------------------------
  wire [15:0] bundle = current[31:16];
  wire [3:0] op = current[15:12];
  wire [11:0] args = current[11:0];
  wire [2:0] pin = args[2:0];
  wire [7:0] pin_mask = 8'b1 << pin;

  wire       bundle_enable = bundle[15];
  wire       bundle_oe_we  = bundle[14];
  wire       bundle_oe     = bundle[13];
  wire       bundle_out_we = bundle[12];
  wire       bundle_out    = bundle[11];
  wire [2:0] bundle_pin    = bundle[10:8];
  wire       bundle_sample = bundle[7];
  wire       bundle_lfsr   = bundle[6];
  wire       bundle_count  = bundle[5];
  wire [4:0] bundle_delay  = bundle[4:0];
  wire [7:0] bundle_mask = 8'b1 << bundle_pin;

  // SHIFT args: [11] receive only, [10] MSB first, [9] duplex receive,
  // [8] open-drain transmit, [7] byte stream, [6:4] RX pin, [2:0] pin.
  wire shift_receive_only = args[11];
  wire shift_msb_first    = args[10];
  wire shift_open_drain   = args[8];
  wire shift_reads = args[11] || args[9];
  wire stream_shift = op == OP_SHIFT && args[7];
  wire tx_bit = shift_msb_first ? tx_shift[15] : tx_shift[0];
  wire rx_bit = shift_receive_only ? pin_timed[pin] : pin_timed[args[6:4]];
  wire [15:0] rx_shift_next = shift_msb_first ?
      {rx_shift[14:0], rx_bit} : {rx_bit, rx_shift[15:1]};

  // A streaming transmit pops its byte on bit 0 and sends that byte's first
  // bit directly; a streaming receive pushes on bit 7.
  wire stream_tx_start = stream_shift && !shift_receive_only &&
                         stream_bit == 0;
  wire stream_rx_done = stream_shift && shift_reads && stream_bit == 7;
  wire shift_tx_bit = stream_tx_start ?
      (shift_msb_first ? tx_data[7] : tx_data[0]) : tx_bit;

  // The slot executes when every FIFO port it needs is granted.
  wire action_accept = (!tx_request || tx_grant) &&
                       (!rx_request || rx_grant);
  wire bundle_exec = bundle_enable && action_accept;
  // Control-flow ops own the PC, so the bundle post-delay is ignored there.
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

  // ---------------------------------------------------------------------------
  // Pin claims
  // ---------------------------------------------------------------------------
  // Pins a slot drives or samples, including its side-set bundle.
  function [7:0] slot_claim;
    input [31:0] word;
    begin
      slot_claim = 8'b0;
      // Bundle pin: driven, or sampled/stepped from it outside SHIFT
      // (SAMPLE and SHIFT sample their own pin instead).
      if (word[31] &&
          (word[30] || word[28] ||
           (word[23] && word[15:12] != OP_SAMPLE &&
                        word[15:12] != OP_SHIFT) ||
           (word[22] && word[15:12] != OP_SHIFT)))
        slot_claim[word[26:24]] = 1'b1;
      case (word[15:12])
        OP_GPIO, OP_SAMPLE:
          slot_claim[word[2:0]] = 1'b1;
        OP_SHIFT: begin
          slot_claim[word[2:0]] = 1'b1;
          if (word[9])
            slot_claim[word[6:4]] = 1'b1;
        end
        OP_PAIR: begin
          slot_claim[word[2:0]] = 1'b1;
          slot_claim[word[5:3]] = 1'b1;
        end
        OP_DELAY:
          if (word[11]) slot_claim[word[10:8]] = 1'b1;
        default: begin end
      endcase
    end
  endfunction

  // A slot becomes ready on its primary or bundle high byte; claim the
  // completed word at that point.
  wire [7:0] written_claim = slot_claim(wr_bundle_hi ?
      {wr_data, current[23:0]} :
      {current[31:16], wr_data, current[7:0]});

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign busy = !idle;
  assign table_ready = ~|(slot_valid & ~slot_ready);
  assign result = result_r;
  assign lfsr_value = lfsr;
  assign launch_claim = table_claim;
  // Table writes wait for idle, so the launch claim is stable while running.
  assign claim = idle ? 8'b0 : table_claim;
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
  // Streaming receive pushes the completed byte; PUSH sends a result byte,
  // [0] selecting the high byte and [4:1] a left shift.
  assign rx_data = stream_rx_done ?
      (shift_msb_first ? rx_shift_next[7:0] : rx_shift_next[15:8]) :
      ((args[0] ? rx_shift[15:8] : rx_shift[7:0]) << args[4:1]);

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  // Stop driving every pin this lane has touched.
  task release_pins;
    begin
      drive_active <= 1'b0;
      out_mask <= 8'b0;
      oe_mask <= 8'b0;
      bundle_out_mask <= 8'b0;
      bundle_oe_mask <= 8'b0;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slot_valid <= 16'b0;
      slot_ready <= 16'b0;
      state <= ST_IDLE;
      pc <= 4'b0;
      base_slot <= 4'b0;
      repeats_left <= 8'b0;
      delay_counter <= 8'b0;
      counter <= 16'b0;
      tx_shift <= 16'b0;
      rx_shift <= 16'b0;
      result_r <= 16'b0;
      lfsr <= 16'hffff;
      lfsr_poly <= 16'h1021;
      stream_bit <= 3'b0;
      sample_bit <= 1'b0;
      table_claim <= 8'b0;
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
      release_pins;
      done_pulse <= 1'b0;
    end else begin
      done_pulse <= 1'b0;

      // Table and shifter writes from the CPU, accepted only while idle.
      if (wr_lo && idle) begin
        // A slot-0 low write starts a new table.
        if (wr_slot == 4'b0) begin
          slot_valid <= 16'b1;
          table_claim <= 8'b0;
        end else
          slot_valid[wr_slot] <= 1'b1;
        slot_ready[wr_slot] <= 1'b0;
      end
      if ((wr_hi || wr_bundle_hi) && idle) begin
        slot_ready[wr_slot] <= 1'b1;
        table_claim <= table_claim | written_claim;
      end
      if (wr_bundle_lo && idle)
        slot_ready[wr_slot] <= 1'b0;
      if (load_shift_lo && idle)
        tx_shift[7:0] <= load_data;
      if (load_shift_hi && idle)
        tx_shift[15:8] <= load_data;
      if (load_tx && idle)
        tx_shift <= load_msb_first ?
            ({8'b0, load_data} << (5'd16 - load_bits)) : {8'b0, load_data};

      if (start && idle && table_ready) begin
        state <= ST_RUN;
        pc <= start_slot;
        base_slot <= start_slot;
        repeats_left <= repeat_count;
        delay_counter <= 8'b0;
        rx_shift <= 16'b0;
        result_r <= 16'b0;
        stream_bit <= 3'b0;
        release_pins;
      end else begin
        case (state)
          // Count down, then optionally wait for a synchronized pin high.
          ST_DELAY: begin
            if (delay_counter == 8'b0 &&
                (!args[11] || pin_sampled[args[10:8]])) begin
              state <= ST_RUN;
              pc <= pc + 1'b1;
            end else if (delay_counter != 8'b0)
              delay_counter <= delay_counter - 1'b1;
          end

          ST_RUN: begin
            // Side-set bundle.
            if (bundle_exec) begin
              drive_active <= 1'b1;
              if (bundle_out_we) begin
                bundle_out_mask <= bundle_out_mask | bundle_mask;
                if (bundle_out)
                  bundle_out_value <= bundle_out_value | bundle_mask;
                else
                  bundle_out_value <= bundle_out_value & ~bundle_mask;
              end
              if (bundle_oe_we) begin
                bundle_oe_mask <= bundle_oe_mask | bundle_mask;
                if (bundle_oe)
                  bundle_oe_value <= bundle_oe_value | bundle_mask;
                else
                  bundle_oe_value <= bundle_oe_value & ~bundle_mask;
              end
              if (bundle_sample && op != OP_SAMPLE && op != OP_SHIFT) begin
                sample_bit <= pin_timed[bundle_pin];
                result_r <= {15'b0, pin_timed[bundle_pin]};
              end
              // The LFSR absorbs the shifted bit during SHIFT, otherwise
              // the bundle pin.
              if (bundle_lfsr)
                lfsr <= lfsr_step(lfsr, lfsr_poly,
                    op == OP_SHIFT ?
                    (shift_reads ? rx_bit : shift_tx_bit) :
                    pin_timed[bundle_pin]);
              if (bundle_count)
                counter <= counter - 1'b1;
            end

            // Primary action.
            if (action_accept) begin
              case (op)
                OP_NOP: pc <= pc + 1'b1;

                // [11] oe_we, [10] oe, [9] out_we, [8] out, [2:0] pin.
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

                // [11] accumulate into result, [10] MSB first, [2:0] pin.
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

                // Separate shifters let TX and RX update on the same cycle.
                OP_SHIFT: begin
                  sample_bit <= rx_bit;
                  if (shift_reads) begin
                    rx_shift <= rx_shift_next;
                    result_r <= rx_shift_next;
                  end
                  if (!shift_receive_only) begin
                    drive_active <= 1'b1;
                    out_mask <= out_mask | pin_mask;
                    oe_mask <= oe_mask | pin_mask;
                    if (shift_open_drain) begin
                      // Open drain: hold the output low and drive only zeros.
                      out_value <= out_value & ~pin_mask;
                      if (shift_tx_bit) oe_value <= oe_value & ~pin_mask;
                      else oe_value <= oe_value | pin_mask;
                    end else begin
                      if (shift_tx_bit) out_value <= out_value | pin_mask;
                      else out_value <= out_value & ~pin_mask;
                      oe_value <= oe_value | pin_mask;
                    end
                    if (stream_tx_start)
                      tx_shift <= shift_msb_first ? {tx_data[6:0], 9'b0} :
                                                    {9'b0, tx_data[7:1]};
                    else if (shift_msb_first)
                      tx_shift <= {tx_shift[14:0], 1'b0};
                    else
                      tx_shift <= {1'b0, tx_shift[15:1]};
                  end
                  if (stream_shift)
                    stream_bit <= stream_bit + 1'b1;
                  pc <= pc + 1'b1;
                end

                // [11:10] mode, [9] finish the region when DJNZ reaches
                // zero, [7:0] load value, [3:0] DJNZ target slot.
                OP_COUNT: begin
                  case (args[11:10])
                    CNT_LOAD: begin counter <= {8'b0, args[7:0]}; pc <= pc + 1'b1; end
                    CNT_INC:  begin counter <= counter + 1'b1;    pc <= pc + 1'b1; end
                    CNT_DEC:  begin counter <= counter - 1'b1;    pc <= pc + 1'b1; end
                    CNT_DJNZ: begin
                      if (counter != 16'd1) begin
                        counter <= counter - 1'b1;
                        pc <= args[3:0];
                      end else begin
                        counter <= 16'b0;
                        if (args[9]) begin
                          done_pulse <= 1'b1;
                          state <= ST_IDLE;
                          release_pins;
                        end else
                          pc <= pc + 1'b1;
                      end
                    end
                  endcase
                end

                // [11:10] mode, [9] high byte for SET_POLY/SET_STATE,
                // [7:0] value. Mode 3 copies the LFSR to result.
                OP_LFSR: begin
                  case (args[11:10])
                    LFSR_STEP: lfsr <= lfsr_step(lfsr, lfsr_poly, tx_shift[0]);
                    LFSR_SET_POLY: begin
                      if (args[9]) lfsr_poly[15:8] <= args[7:0];
                      else lfsr_poly[7:0] <= args[7:0];
                    end
                    LFSR_SET_STATE: begin
                      if (args[9]) lfsr[15:8] <= args[7:0];
                      else lfsr[7:0] <= args[7:0];
                    end
                    default: result_r <= lfsr;
                  endcase
                  pc <= pc + 1'b1;
                end

                // [11:8] condition, [3:0] target slot.
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

                // [7:0] cycles, [11] then wait for synchronized pin [10:8]
                // high.
                OP_DELAY: begin
                  if (args[7:0] == 0 &&
                      (!args[11] || pin_sampled[args[10:8]]))
                    pc <= pc + 1'b1;
                  else begin
                    delay_counter <= args[7:0] == 0 ? 8'b0 :
                                     args[7:0] - 8'd1;
                    state <= ST_DELAY;
                  end
                end

                OP_REPEAT: pc <= args[3:0];

                // Classify pins A [2:0] and B [5:3]: both low 0, both
                // high 3, otherwise 1 when A equals [6] and 2 when not.
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

                // Load the popped byte; [5] MSB first, aligned for [4:0]
                // bits (0 means 16).
                OP_PULL: begin
                  tx_shift <= args[5] ?
                      ({8'b0, tx_data} << (5'd16 -
                       (args[4:0] == 0 ? 5'd16 : args[4:0]))) :
                      {8'b0, tx_data};
                  pc <= pc + 1'b1;
                end

                OP_PUSH: pc <= pc + 1'b1;

                // Release pins, then repeat from the start slot or finish.
                OP_DONE: begin
                  release_pins;
                  if (repeats_left != 0) begin
                    repeats_left <= repeats_left - 1'b1;
                    pc <= base_slot;
                  end else begin
                    done_pulse <= 1'b1;
                    state <= ST_IDLE;
                  end
                end

                default: pc <= pc + 1'b1;
              endcase

              if (bundle_exec && bundle_delay_ok && bundle_delay != 0) begin
                delay_counter <= {3'b0, bundle_delay} - 1'b1;
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

// One byte of action-table storage: eight transparent-high latches. The
// LibreLane flow instantiates the IHP latch cell directly so its latch lint
// stays clean; simulation and other tools use the behavioral equivalent.
module action_slot_byte (
    input  wire       gate,
    input  wire [7:0] d,
    output wire [7:0] q
);
`ifdef __librelane__
  genvar bit_index;
  generate
    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin : g_bit
      sg13cmos5l_dlhq_1 latch (.Q(q[bit_index]), .D(d[bit_index]), .GATE(gate));
    end
  endgenerate
`else
  reg [7:0] value;
  // verilator lint_off LATCH
  always @(*)
    if (gate)
      value = d;
  // verilator lint_on LATCH
  assign q = value;
`endif
endmodule

`default_nettype wire
