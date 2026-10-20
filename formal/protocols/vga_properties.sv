`default_nettype none

// Protocol proof: the whole core runs the real VGA program (rom.vh) with
// a symbolic TX FIFO that always has the next byte (the host keeps ahead;
// every line's byte is tagged eop). Lines are numbered from the first
// HSYNC fall F0: line k's HSYNC falls at F0 + k * LINE, so it is low for
// exactly SYNC cycles every LINE cycles. The colour pins all agree; seen
// D = FRONT + VISIBLE cycles late, the pixel at position p of line k is
// the next popped byte's bit 7 - p / CELL for p < VISIBLE in the visible
// rows of a frame, and black otherwise (the porches, blank lines and
// everything before line 0); VSYNC, seen D + 1 late, is low exactly in
// the VSYNC rows.
module vga_properties (input wire clk);
  localparam CELL = 3, CELLS = 8, FRONT = 1, SYNC = 1, BACK = 1;
  localparam V_VISIBLE = 1, V_FRONT = 1, V_SYNC = 1, V_BACK = 1;
  localparam VISIBLE = CELL * CELLS, LINE = VISIBLE + FRONT + SYNC + BACK;
  localparam FRAME = V_VISIBLE + V_FRONT + V_SYNC + V_BACK, D = FRONT + VISIBLE;
  localparam VSYNC = 3, HSYNC = 7;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg [7:0] arriving;
  reg       configured = 1'b0;
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

  // One byte a line, so every byte ends its line (eop).
  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(rst_n),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data({10'd0, 2'b01, head}), .tx_empty({1'b1, !configured}), .tx_pop(tx_pop),
      .tx_full(2'b00), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(2'b00),
      .gpio_in(8'hff), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && gpio_oe != 8'd0)
      configured <= 1'b1;
    if (tx_pop[0] || !configured)
      head <= configured ? arriving : 8'd0;
  end

  wire hs = gpio_out[HSYNC], vs = gpio_out[VSYNC];
  wire px = gpio_out[0];
  reg  hs_q = 1'b1;
  reg  started = 1'b0;                 // F0 has happened
  reg  [7:0] p = 8'd0;                 // position in the line, from its HSYNC fall
  reg  [7:0] k = 8'd0;                 // line number (saturating)
  reg  [D:0] px_hist = 0;              // px_hist[i] = pixel i + 1 cycles ago
  reg  [D+1:0] vs_hist = {(D + 2){1'b1}};
  wire fall = configured && !hs && hs_q;
  // Line and position of the cycle being judged (now, or F0's own cycle).
  wire [7:0] p_now = !started ? 8'd0 : (p == LINE - 1 ? 8'd0 : p + 8'd1);
  wire [7:0] k_now = !started ? 8'd0 : (p == LINE - 1 ? k + 8'd1 : k);
  wire judged = started || fall;
  wire [7:0] row = k_now % FRAME;

  // Popped bytes in order (the byte tiles pop ahead of the shifter).
  reg [7:0] popped [0:3];
  reg [2:0] popped_n = 3'd0;
  integer i;
  initial for (i = 0; i < 4; i = i + 1) popped[i] = 8'd0;
  wire line_end = judged && row < V_VISIBLE && p_now == VISIBLE - 1;
  wire [2:0] used = line_end ? 3'd1 : 3'd0;

  always @(posedge clk) begin
    if (!rst_n) begin
      popped_n <= 3'd0;
    end else begin
      hs_q <= hs;
      if (fall) started <= 1'b1;
      if (judged) begin
        p <= p_now;
        k <= k_now;
      end
      px_hist <= {px_hist[D-1:0], px};
      vs_hist <= {vs_hist[D:0], vs};
      for (i = 0; i < 4; i = i + 1)
        popped[i] <= (i + used < 4) ? popped[i + used] : 8'd0;
      if (tx_pop[0]) popped[popped_n - used] <= head;
      popped_n <= popped_n - used + tx_pop[0];
    end
  end

  wire px_late = px_hist[D-1];          // the pixel D cycles ago
  wire vs_late = vs_hist[D];            // VSYNC D + 1 cycles ago
  wire in_window = judged && row < V_VISIBLE && p_now < VISIBLE;
  // The line's byte, shifted left once a cell: its top bit is this cell's.
  reg  [7:0] bits = 8'd0;
  reg  [7:0] in_cell = 8'd0;            // cycles into the current cell
  wire [7:0] bits_now = (p_now == 8'd0) ? popped[0] :
                        (in_cell == CELL - 1) ? {bits[6:0], 1'b0} : bits;
  wire [2:0] cell = p_now / CELL;
  always @(posedge clk)
    if (rst_n && judged) begin
      bits <= bits_now;
      in_cell <= (p_now == 8'd0 || in_cell == CELL - 1) ? 8'd0 : in_cell + 8'd1;
    end
  wire want_px = in_window && bits_now[7];
  wire want_vs = !(judged && row >= V_VISIBLE + V_FRONT && row < V_VISIBLE + V_FRONT + V_SYNC);

  always @(*) begin
    if (rst_n && configured) begin
      assert(tx_pop[1] == 1'b0 && popped_n <= 3'd3);
      assert(gpio_out[1] == px && gpio_out[2] == px && gpio_out[4] == px &&
             gpio_out[5] == px && gpio_out[6] == px);
      assert(gpio_oe == 8'hff);
      if (judged) assert(hs == !(p_now < SYNC));        // HSYNC: exactly SYNC low each line
      if (!judged) assert(hs);
      if (in_window) assert(popped_n != 3'd0);
      assert(px_late == want_px);                        // every pixel, every cycle
      if (judged) assert(vs_late == want_vs);            // VSYNC rows
      cover(judged && k_now == FRAME && p_now == VISIBLE - 1);   // a frame and the next one's first line
      cover(in_window && px_late && cell == 3'd7);
    end
  end
endmodule

`default_nettype wire
