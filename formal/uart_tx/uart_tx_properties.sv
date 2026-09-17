`default_nettype none

module uart_tx_properties;
  localparam SYMBOL_CYCLES = 12;

  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  wire rst_n = reset_cycles >= 2;
  reg [1:0] reset_cycles = 2'b0;
  reg enable = 1'b1;
  (* anyconst *) reg [7:0] payload;

  wire [9:0] instruction_address;
  wire instruction_read;
  reg [7:0] instruction_data;
  reg tx_empty = 1'b0;
  wire tx_pop;
  wire [7:0] rx_data;
  wire rx_push;
  wire [7:0] gpio_out;
  wire [7:0] gpio_oe;
  wire halted;

  always @(*) begin
    case (instruction_address)
      10'd0: instruction_data = 8'h38;
      10'd1: instruction_data = 8'h28;
      10'd2: instruction_data = 8'h40;
      10'd3: instruction_data = 8'h20;
      10'd4: instruction_data = 8'h10;
      10'd5: instruction_data = 8'h01;
      10'd6: instruction_data = 8'h00;
      10'd7, 10'd11, 10'd15, 10'd19,
      10'd23, 10'd27, 10'd31, 10'd35:
        instruction_data = 8'h50;
      10'd8, 10'd12, 10'd16, 10'd20,
      10'd24, 10'd28, 10'd32, 10'd36,
      10'd40: instruction_data = 8'h10;
      10'd9, 10'd13, 10'd17, 10'd21,
      10'd25, 10'd29, 10'd33, 10'd37,
      10'd41: instruction_data = 8'h01;
      10'd10, 10'd14, 10'd18, 10'd22,
      10'd26, 10'd30, 10'd34, 10'd38,
      10'd42, 10'd45: instruction_data = 8'h00;
      10'd39: instruction_data = 8'h28;
      10'd43: instruction_data = 8'h80;
      10'd44: instruction_data = 8'h02;
      default: instruction_data = 8'h01;
    endcase
  end

  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data(payload), .tx_empty(tx_empty), .tx_pop(tx_pop),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(1'b0),
      .gpio_in(8'b0), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  reg tx_seen = 1'b0;
  reg in_frame = 1'b0;
  reg completed = 1'b0;
  reg [3:0] frame_bit = 4'b0;
  reg [4:0] phase = 5'b0;
  // Avoid variable bit-selects (they can leave X in the AIGER netlist).
  reg expected_level;
  reg next_level;
  always @(*) begin
    case (frame_bit)
      4'd0: expected_level = 1'b0;
      4'd1: expected_level = payload[0];
      4'd2: expected_level = payload[1];
      4'd3: expected_level = payload[2];
      4'd4: expected_level = payload[3];
      4'd5: expected_level = payload[4];
      4'd6: expected_level = payload[5];
      4'd7: expected_level = payload[6];
      4'd8: expected_level = payload[7];
      default: expected_level = 1'b1;
    endcase
    case (frame_bit)
      4'd0: next_level = payload[0];
      4'd1: next_level = payload[1];
      4'd2: next_level = payload[2];
      4'd3: next_level = payload[3];
      4'd4: next_level = payload[4];
      4'd5: next_level = payload[5];
      4'd6: next_level = payload[6];
      4'd7: next_level = payload[7];
      default: next_level = 1'b1;
    endcase
  end

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;

    if (!rst_n) begin
      tx_empty <= 1'b0;
      tx_seen <= 1'b0;
      in_frame <= 1'b0;
      completed <= 1'b0;
      frame_bit <= 4'b0;
      phase <= 5'b0;
    end else begin
      if (tx_pop) begin
        assert(!tx_seen);
        assert(!tx_empty);
        tx_seen <= 1'b1;
        tx_empty <= 1'b1;
      end

      if (!in_frame && tx_seen && gpio_oe[0] && !gpio_out[0]) begin
        in_frame <= 1'b1;
        frame_bit <= 4'd0;
        phase <= 5'd0;
      end else if (in_frame) begin
        assert(gpio_oe[0]);
        if (phase == SYMBOL_CYCLES - 1)
          assert(gpio_out[0] == next_level);
        else
          assert(gpio_out[0] == expected_level);

        if (phase == SYMBOL_CYCLES - 1) begin
          phase <= 5'd0;
          if (frame_bit == 4'd9) begin
            in_frame <= 1'b0;
            completed <= 1'b1;
          end else begin
            frame_bit <= frame_bit + 1'b1;
          end
        end else begin
          phase <= phase + 1'b1;
        end
      end

      if (completed) begin
        assert(gpio_oe[0]);
        assert(gpio_out[0]);
        assert(tx_empty);
      end
      cover(completed);
    end
  end

  wire _unused = &{instruction_read, rx_data, rx_push, halted, 1'b0};
endmodule

`default_nettype wire
