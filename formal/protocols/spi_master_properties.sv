`default_nettype none

// Protocol proof: the whole core runs the real SPI mode-0 master program
// (rom.vh): one transaction of NBYTES bytes, which the host supplies at any
// times (the FIFO may run dry between them), against a symbolic MISO.
// While CS is high SCK rests low and never moves; CS falls at least HALF
// cycles before SCK's first edge; within a byte every SCK half period is
// exactly HALF cycles, and between bytes SCK may only pause (at its idle
// level); CS rises only between bytes; MOSI never moves while SCK is high;
// at every rising edge MOSI is the next bit (MSB first) of the popped
// bytes, in order; SCK never runs without a byte.
module spi_master_properties (input wire clk);
  localparam HALF = 3, NBYTES = 2, CS = 0, MOSI = 1, SCK = 3;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  // TX FIFO channel 0: a head byte that holds until popped; any bytes, any
  // gaps. Channel 1 stays empty.
  (* anyseq *) reg       arrive;
  (* anyseq *) reg [7:0] miso_in;
  (* anyseq *) reg [7:0] arriving;
  reg       has = 1'b0;
  // The program armed the fabric (it drives a pin). Until then the host
  // supplies nothing and inputs are constant, so everything before is one
  // deterministic run: prearm.py simulates it and the proof starts there.
  reg       configured = 1'b0;
  reg [2:0] provided = 3'd0;     // bytes the host has supplied
  reg [7:0] head = 8'd0;

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire [1:0]  tx_pop, tx_push, rx_push;
  wire [9:0]  tx_push_data;
  wire [7:0]  gpio_out, gpio_oe;
  wire [19:0] rx_data;
  wire        halted;
  reg  [7:0]  instruction_data = 8'd0;
  always @(posedge clk)
    if (instruction_read)
      instruction_data <= rom_byte(instruction_address);

  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(rst_n),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data({10'd0, 2'b00, head}), .tx_empty({1'b1, !has}), .tx_pop(tx_pop),
      .tx_full(2'b00), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(2'b00),
      .gpio_in(configured ? miso_in : 8'hff), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && gpio_oe != 8'd0)
      configured <= 1'b1;
    if (!rst_n) begin
      has <= 1'b0;
      provided <= 3'd0;
    end else if (!has || tx_pop[0]) begin
      has  <= configured && arrive && provided < NBYTES;
      head <= configured ? arriving : 8'd0;
      if (configured && arrive && provided < NBYTES) provided <= provided + 3'd1;
    end
  end

  reg [7:0] q [0:3];
  reg [2:0] count = 3'd0;
  reg [2:0] bit_index = 3'd0;
  reg       sck_q = 1'b0, mosi_q = 1'b0, cs_q = 1'b1, seen = 1'b0;
  reg [7:0] run = 8'd0;          // cycles since SCK last changed
  reg [7:0] cs_low_for = 8'd0;
  reg       first_edge = 1'b1;   // no SCK edge yet since CS fell
  initial begin q[0] = 0; q[1] = 0; q[2] = 0; q[3] = 0; end
  wire sck  = gpio_oe[SCK] && gpio_out[SCK];
  wire mosi = gpio_out[MOSI];
  wire cs   = !gpio_oe[CS] || gpio_out[CS];
  wire rise = sck && !sck_q;
  wire edge = sck != sck_q;
  wire byte_done = rise && bit_index == 3'd7;

  always @(posedge clk) begin
    if (!rst_n) begin
      count <= 3'd0; bit_index <= 3'd0; sck_q <= 1'b0; cs_q <= 1'b1; seen <= 1'b0;
      run <= 8'd0; cs_low_for <= 8'd0; first_edge <= 1'b1;
    end else begin
      sck_q <= sck; mosi_q <= mosi; cs_q <= cs;
      if (edge) seen <= 1'b1;
      run <= edge ? 8'd1 : (run == 8'hff ? run : run + 8'd1);
      cs_low_for <= cs ? 8'd0 : (cs_low_for == 8'hff ? cs_low_for : cs_low_for + 8'd1);
      if (cs) first_edge <= 1'b1;
      else if (edge) first_edge <= 1'b0;
      if (rise) bit_index <= bit_index + 3'd1;
      if (byte_done) begin
        q[0] <= q[1]; q[1] <= q[2]; q[2] <= q[3];
      end
      if (tx_pop[0])
        q[byte_done ? count - 3'd1 : count] <= head;
      count <= count + tx_pop[0] - byte_done;
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(tx_pop[1] == 1'b0);
      assert(count <= 3'd4);
      if (cs) assert(!sck);                                        // idle low
      if (edge && first_edge) assert(!cs && cs_low_for >= HALF);   // CS setup
      if (edge && !first_edge && !(rise && bit_index == 3'd0))
        assert(run == HALF);                                       // exact within a byte
      if (rise && !first_edge && bit_index == 3'd0)
        assert(run >= HALF);                                       // a pause between bytes
      if (cs && !cs_q) assert(bit_index == 3'd0 && !sck);          // CS rises between bytes
      if (sck && sck_q) assert(mosi == mosi_q);                    // MOSI stable while high
      if (rise) assert(count != 3'd0 && mosi == q[0][3'd7 - bit_index]);
      cover(rise);
      cover(rise && bit_index == 3'd4);
      cover(byte_done);
      cover(byte_done && q[0] == 8'h5a);
    end
  end
endmodule

`default_nettype wire
