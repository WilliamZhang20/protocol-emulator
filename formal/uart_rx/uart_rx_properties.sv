`default_nettype none

module uart_rx_properties;
  localparam SYMBOL_CYCLES = 12;
  localparam FIRST_SAMPLE_WAIT = 6;

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
  reg [7:0] gpio_in;
  wire [7:0] gpio_out;
  wire [7:0] gpio_oe;
  wire tx_pop;
  wire [7:0] rx_data;
  wire rx_push;
  wire halted;

  always @(*) begin
    case (instruction_address)
      10'd0: instruction_data = 8'h30;
      10'd1: instruction_data = 8'h90;
      10'd2: instruction_data = 8'h10;
      10'd3: instruction_data = FIRST_SAMPLE_WAIT;
      10'd4: instruction_data = 8'h00;
      10'd5: instruction_data = 8'ha0;
      10'd6, 10'd10, 10'd14, 10'd18,
      10'd22, 10'd26, 10'd30, 10'd34:
        instruction_data = 8'h60;
      10'd7, 10'd11, 10'd15, 10'd19,
      10'd23, 10'd27, 10'd31, 10'd35:
        instruction_data = 8'h10;
      10'd8, 10'd12, 10'd16, 10'd20,
      10'd24, 10'd28, 10'd32, 10'd36:
        instruction_data = 8'h01;
      10'd9, 10'd13, 10'd17, 10'd21,
      10'd25, 10'd29, 10'd33, 10'd37,
      10'd42: instruction_data = 8'h00;
      10'd38: instruction_data = 8'h70;
      10'd39: instruction_data = 8'h98;
      10'd40: instruction_data = 8'h80;
      10'd41: instruction_data = 8'h01;
      default: instruction_data = 8'h01;
    endcase
  end

  reg [7:0] launch_count = 8'b0;
  reg source_active = 1'b0;
  reg [3:0] source_bit = 4'b0;
  reg [4:0] source_phase = 5'b0;
  wire source_level = source_bit == 0 ? 1'b0 :
                      source_bit <= 8 ? payload[source_bit - 1'b1] : 1'b1;

  always @(*) begin
    gpio_in = 8'hff;
    if (source_active)
      gpio_in[0] = source_level;
  end

  protocol_emulator_core dut (
      .clk(clk),
      .rst_n(rst_n),
      .enable(enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data(8'b0),
      .tx_empty(1'b1),
      .tx_pop(tx_pop),
      .rx_data(rx_data),
      .rx_push(rx_push),
      .rx_full(1'b0),
      .gpio_in(gpio_in),
      .gpio_out(gpio_out),
      .gpio_oe(gpio_oe),
      .halted(halted)
  );

  reg received = 1'b0;

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;

    if (!rst_n) begin
      launch_count <= 8'b0;
      source_active <= 1'b0;
      source_bit <= 4'b0;
      source_phase <= 5'b0;
      received <= 1'b0;
    end else begin
      if (!source_active && launch_count < 8'd10)
        launch_count <= launch_count + 1'b1;
      else if (!source_active && launch_count == 8'd10 && !received) begin
        source_active <= 1'b1;
        source_bit <= 4'd0;
        source_phase <= 5'd0;
        launch_count <= launch_count + 1'b1;
      end else if (source_active) begin
        if (source_phase == SYMBOL_CYCLES - 1) begin
          source_phase <= 5'd0;
          if (source_bit == 4'd9)
            source_active <= 1'b0;
          else
            source_bit <= source_bit + 1'b1;
        end else begin
          source_phase <= source_phase + 1'b1;
        end
      end

      if (rx_push) begin
        assert(!received);
        assert(rx_data == payload);
        received <= 1'b1;
      end

      cover(received);
    end
  end

  wire _unused = &{instruction_read, gpio_out, 1'b0};
endmodule

`default_nettype wire
