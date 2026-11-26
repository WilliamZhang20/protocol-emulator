`default_nettype none

// CRC tile additive mode (8-bit words) against a word-level model written
// the textbook way: bits are collected LSB first into a byte, and at each
// byte the model adds it to its sum, folding the carry back immediately
// (one's complement, LIN / RFC 1071) or dropping it (two's complement).
// The tile adds bit-serially with a deferred carry; at every word boundary
// its `value` must equal the model's sum. Emitting then sends the
// complemented sum LSB first. Absorb, data, emit and init lines are
// arbitrary every cycle (absorbs and emits are not mixed within a word:
// emit is only meaningful at a boundary, and absorbing after an emit
// starts a new sum only after an init).
module fabric_crc_additive_properties (input wire clk);
  reg [3:0] t = 4'd0;
  always @(posedge clk) if (t != 4'd15) t <= t + 4'd1;
  wire rst_n = t >= 4'd2;
  wire configured = t >= 4'd6;

  (* anyconst *) reg twos, ones_init;
  (* anyseq *) reg absorb, data, emit, init;

  // Configuration, one register a cycle while disabled, then run:
  // absorb line 2, data level 1 (line 33), emit line 3, init line 4, width 8.
  reg cfg_we; reg [2:0] cfg_addr; reg [15:0] cfg_data;
  always @(*) begin
    cfg_we = rst_n && !configured;
    cfg_addr = 3'd0; cfg_data = 16'd0;
    case (t)
      4'd2: begin cfg_addr = 3'd4; cfg_data = {5'd0, 5'd1, 6'd2}; end
      4'd3: begin cfg_addr = 3'd5; cfg_data = {5'd0, 5'd4, 6'd3}; end
      4'd4: begin cfg_addr = 3'd6; cfg_data = {6'd0, twos, 1'b1, 1'b0, 1'b0, ones_init, 5'd7}; end
      4'd5: begin cfg_addr = 3'd7; cfg_data = 16'd0; end
      default: cfg_we = 1'b0;
    endcase
  end
  wire enable = configured;
  wire run_absorb = configured && absorb;
  wire run_emit   = configured && emit;
  wire run_init   = configured && init;
  wire [63:0] lines = {30'b0, data, 1'b0, 27'b0, run_init, run_emit, run_absorb, 2'b0};

  wire out, tail_out, ok;
  wire [31:0] value;
  fabric_crc dut(.clk(clk), .rst_n(rst_n), .enable(enable), .cfg_we(cfg_we), .cfg_addr(cfg_addr),
      .cfg_data(cfg_data), .lines(lines), .link_absorb(2'b0), .link_bit(2'b0), .link_emit(2'b0),
      .out(out), .tail_out(tail_out), .ok(ok), .value(value));

  // ---- word-level model
  reg [7:0] sum = 8'd0, byte_acc = 8'd0;
  reg [2:0] count = 3'd0;
  reg emitted = 1'b0;            // an emit since the last init
  reg [7:0] sent = 8'd0;         // the complemented sum still to be sent, LSB first
  wire [8:0] added = {1'b0, sum} + {1'b0, data, byte_acc[7:1]};
  wire [7:0] next_sum = twos ? added[7:0] : (added[8] ? added[7:0] + 8'd1 : added[7:0]);

  // Within a sum: no emit mid-word, no absorb once emitting.
  always @(*) if (configured && !init) begin
    if (count != 3'd0) assume(!emit);
    if (emitted) assume(!absorb);
  end

  always @(posedge clk) begin
    if (!configured) begin
      sum <= ones_init ? 8'hff : 8'h00; byte_acc <= 8'd0; count <= 3'd0; emitted <= 1'b0;
      sent <= ones_init ? 8'h00 : 8'hff;
    end else if (init) begin
      sum <= ones_init ? 8'hff : 8'h00; byte_acc <= 8'd0; count <= 3'd0; emitted <= 1'b0;
      sent <= ones_init ? 8'h00 : 8'hff;
    end else if (absorb) begin
      byte_acc <= {data, byte_acc[7:1]};
      count <= count + 3'd1;
      if (count == 3'd7) begin
        sum <= next_sum;
        sent <= ~next_sum;
      end
    end else if (emit) begin
      emitted <= 1'b1;
      sent <= {1'b1, sent[7:1]};   // the emptied top reads as a complemented 0
    end
  end

  always @(*) begin
    if (configured && t >= 4'd7) begin
      if (count == 3'd0 && !emitted) assert(value[7:0] == sum);
      if (count == 3'd0) assert(out == sent[0]);
      cover(count == 3'd0 && !emitted && !twos && sum == 8'h01 && value[7:0] == 8'h01);
      cover(count == 3'd0 && !emitted && twos && sum == 8'h00 && t == 4'd15);
    end
  end
endmodule

`default_nettype wire
