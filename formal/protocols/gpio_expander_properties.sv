`default_nettype none

// Protocol proof: the whole core runs the real GPIO expander program
// (rom.vh, half period HALF) driving a chain of NBYTES 74HC595s and NBYTES
// 74HC165s (one of each here; longer chains repeat the same per-byte
// fabric and are covered by the cocotb tests), modelled
// here at the core's pins. The TX FIFO is symbolic: any bytes, arriving at
// any times, including bytes for later updates that are already waiting
// when an update ends. The 165s' parallel inputs are symbolic and change
// at will. Then: every RCLK rise latches exactly the next NBYTES popped
// bytes into the 595 outputs (first byte in the farthest chip), after
// exactly 8 * NBYTES SRCLK rises in that update; every byte pushed to RX is
// the next byte of the 165 inputs captured when SH/LD# rose (nearest chip
// first); SRCLK never rises while the 165s load; SER never changes in the
// cycle SRCLK rises; SRCLK rests low between updates.
module gpio_expander_properties (input wire clk);
  localparam HALF = 4, NBYTES = 1, BITS = 8 * NBYTES;
  localparam RCLK = 0, SER = 1, QH = 2, SRCLK = 3, LOAD = 4;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg            arrive;
  (* anyseq *) reg [7:0]      arriving;
  (* anyseq *) reg [BITS-1:0] parallel_in;
  reg       has = 1'b0;
  reg       configured = 1'b0;   // armed (a pin driven); before: one deterministic run
  reg [7:0] head = 8'd0;

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire [1:0]  tx_pop, tx_push, rx_push;
  wire [9:0]  tx_push_data;
  wire [7:0]  gpio_out, gpio_oe;
  wire [19:0] rx_data;
  wire        halted;
  reg  [7:0]  instruction_data = 8'd0;
  reg  [BITS-1:0] r165 = {BITS{1'b0}};
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
      .gpio_in({5'b11111, r165[BITS-1], 2'b11}), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && gpio_oe != 8'd0)
      configured <= 1'b1;
    if (!rst_n) begin
      has <= 1'b0;
    end else if (!has || tx_pop[0]) begin
      has  <= configured && arrive;
      head <= configured ? arriving : 8'd0;
    end
  end

  // The chips. Pins not yet driven read as the pull-ups (high).
  wire srclk  = gpio_oe[SRCLK] && gpio_out[SRCLK];
  wire ser    = gpio_out[SER];
  wire rclk   = !gpio_oe[RCLK] || gpio_out[RCLK];
  wire load_n = !gpio_oe[LOAD] || gpio_out[LOAD];
  reg  srclk_q = 1'b0, ser_q = 1'b0, rclk_q = 1'b1, load_n_q = 1'b1;
  wire srclk_rise = srclk && !srclk_q;
  wire rclk_rise  = rclk && !rclk_q;
  wire load_rise  = load_n && !load_n_q;
  reg  [BITS-1:0] sh595 = {BITS{1'b0}};
  reg  [BITS-1:0] captured = {BITS{1'b0}};
  reg  [7:0] edges = 8'd0;              // SRCLK rises since SH/LD# rose
  reg        updated = 1'b0;            // an update has completed

  // Popped bytes in order (the byte tiles may pop ahead of the shifter).
  reg [7:0] popped [0:7];
  reg [3:0] popped_n = 4'd0;
  // Input bytes due on RX, in order.
  reg [7:0] due [0:7];
  reg [3:0] due_n = 4'd0;
  integer i;
  initial for (i = 0; i < 8; i = i + 1) begin popped[i] = 8'd0; due[i] = 8'd0; end

  reg  [BITS-1:0] expected_out;
  always @(*)
    for (i = 0; i < NBYTES; i = i + 1)
      expected_out[BITS-1-8*i -: 8] = popped[i];
  wire [3:0] used = rclk_rise ? NBYTES : 4'd0;
  wire [3:0] taken = rx_push[0] ? 4'd1 : 4'd0;

  always @(posedge clk) begin
    if (!rst_n) begin
      srclk_q <= 1'b0; rclk_q <= 1'b1; load_n_q <= 1'b1;
      popped_n <= 4'd0; due_n <= 4'd0; edges <= 8'd0; updated <= 1'b0;
    end else begin
      srclk_q <= srclk; ser_q <= ser; rclk_q <= rclk; load_n_q <= load_n;
      if (srclk_rise) sh595 <= {sh595[BITS-2:0], ser};
      if (!load_n) r165 <= parallel_in;
      else if (srclk_rise) r165 <= {r165[BITS-2:0], 1'b0};
      if (load_rise) begin
        captured <= r165;
        edges <= 8'd0;
      end else if (srclk_rise)
        edges <= edges + 8'd1;
      if (rclk_rise) updated <= 1'b1;
      // Popped-byte queue: consume NBYTES at an RCLK rise, append pops.
      for (i = 0; i < 8; i = i + 1)
        popped[i] <= (i + used < 8) ? popped[i + used] : 8'd0;
      if (tx_pop[0]) popped[popped_n - used] <= head;
      popped_n <= popped_n - used + tx_pop[0];
      // RX bytes due: append the captured inputs at SH/LD# rise.
      for (i = 0; i < 8; i = i + 1)
        due[i] <= (i + taken < 8) ? due[i + taken] : 8'd0;
      if (load_rise)
        for (i = 0; i < NBYTES; i = i + 1)
          due[due_n - taken + i] <= r165[BITS-1-8*i -: 8];
      due_n <= due_n - taken + (load_rise ? NBYTES : 4'd0);
    end
  end

  always @(*) begin
    if (rst_n && configured) begin
      assert(tx_pop[1] == 1'b0);
      assert(popped_n <= 4'd6 && due_n <= 4'd6);
      if (srclk_rise) assert(load_n);                   // never clock while loading
      if (srclk_rise) assert(ser == ser_q);             // SER stable at the edge
      if (srclk_rise) assert(edges < BITS);              // never more bits than the chain
      if (rclk) assert(!srclk);                          // SRCLK rests low between updates
      if (rclk_rise) begin                               // an update latches its own bytes
        assert(popped_n >= NBYTES);
        assert(edges == BITS);
        assert(sh595 == expected_out);
      end
      if (rx_push[0]) begin                              // inputs come back in order
        assert(due_n != 4'd0);
        assert(rx_data[7:0] == due[0]);
      end
      assert(rx_push[1] == 1'b0);
      cover(rclk_rise && sh595 == 8'ha5);
      cover(rx_push[0] && due_n == 4'd1 && rx_data[7:0] == 8'h3c);
    end
  end
endmodule

`default_nettype wire
