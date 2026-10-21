`default_nettype none

// Protocol proof: the whole core runs the real frame-buffer VGA program
// (rom.vh) with a symbolic image: the first time the controller reads an
// image byte from SRAM it is any value, and it keeps that value. The
// program copies the image into the real 4-entry TX FIFO 0 itself; the
// host sends nothing. Lines are numbered from the first HSYNC fall F0, as
// in vga_properties.sv: HSYNC is low for exactly SYNC cycles every LINE
// cycles; the colour pins all agree; seen D = FRONT + VISIBLE cycles
// late, the pixel at position p of line k is, in the visible lines of a
// frame, bit 7 - p / CELL of image row (line in frame) / ROW_LINES, a byte
// the controller has read, and black otherwise; VSYNC, seen D + 1 late,
// is low exactly in the VSYNC lines. The depth covers a whole frame (both
// rows, each on two lines) and the next frame's first line.
module vga_framebuffer_properties (input wire clk);
  localparam CELL = 3, CELLS = 8, FRONT = 16, SYNC = 12, BACK = 12;
  localparam ROWS = 2, ROW_LINES = 2;
  localparam V_VISIBLE = ROWS * ROW_LINES, V_FRONT = 1, V_SYNC = 1, V_BACK = 1;
  localparam VISIBLE = CELL * CELLS, LINE = VISIBLE + FRONT + SYNC + BACK;
  localparam FRAME = V_VISIBLE + V_FRONT + V_SYNC + V_BACK, D = FRONT + VISIBLE;
  localparam VSYNC = 3, HSYNC = 7;
  `include "rom.vh"

  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  reg configured = 1'b0;

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire [1:0]  tx_pop, tx_push, rx_push;
  wire [9:0]  tx_push_data;
  wire [7:0]  gpio_out, gpio_oe;
  wire [19:0] rx_data;
  wire        halted;
  wire [9:0]  head0;
  wire        empty0, full0;

  // SRAM: the program, except the image bytes, which are symbolic.
  (* anyseq *) reg [7:0] any_byte;
  reg  [7:0]  instruction_data = 8'd0;
  reg  [ROWS-1:0]   seen = {ROWS{1'b0}};
  reg  [8*ROWS-1:0] image = {(8 * ROWS){1'b0}};
  wire in_image = instruction_address >= TABLE0 &&
                  instruction_address < TABLE0 + TABLE0_LENGTH;
  wire [9:0] at = instruction_address - TABLE0;
  always @(posedge clk)
    if (instruction_read) begin
      if (!in_image)
        instruction_data <= rom_byte(instruction_address);
      else if (seen[at])
        instruction_data <= image[8 * at +: 8];
      else begin
        instruction_data <= any_byte;
        image[8 * at +: 8] <= any_byte;
        seen[at] <= 1'b1;
      end
    end

  byte_fifo #(.DEPTH(4), .ADDRESS_WIDTH(2), .WIDTH(10)) channel0 (
      .clk(clk), .rst_n(rst_n), .push(tx_push[0]), .push_data(tx_push_data),
      .pop(tx_pop[0]), .pop_data(head0), .empty(empty0), .full(full0), .level());

  protocol_emulator_core dut (
      .clk(clk), .rst_n(rst_n), .enable(rst_n),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .tx_data({10'd0, head0}), .tx_empty({1'b1, empty0}), .tx_pop(tx_pop),
      .tx_full({1'b0, full0}), .tx_push(tx_push), .tx_push_data(tx_push_data),
      .rx_data(rx_data), .rx_push(rx_push), .rx_full(2'b00),
      .gpio_in(8'hff), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
      .halted(halted)
  );

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n && gpio_oe != 8'd0)
      configured <= 1'b1;
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
  wire [7:0] p_now = !started ? 8'd0 : (p == LINE - 1 ? 8'd0 : p + 8'd1);
  wire [7:0] k_now = !started ? 8'd0 : (p == LINE - 1 ? k + 8'd1 : k);
  wire judged = started || fall;
  wire [7:0] line_in_frame = k_now % FRAME;
  wire [7:0] row = line_in_frame / ROW_LINES;

  always @(posedge clk)
    if (rst_n) begin
      hs_q <= hs;
      if (fall) started <= 1'b1;
      if (judged) begin
        p <= p_now;
        k <= k_now;
      end
      px_hist <= {px_hist[D-1:0], px};
      vs_hist <= {vs_hist[D:0], vs};
    end

  wire px_late = px_hist[D-1];          // the pixel D cycles ago
  wire vs_late = vs_hist[D];            // VSYNC D + 1 cycles ago
  wire in_window = judged && line_in_frame < V_VISIBLE && p_now < VISIBLE;
  // The row's byte, shifted left once a cell: its top bit is this cell's.
  reg  [7:0] bits = 8'd0;
  reg  [7:0] in_cell = 8'd0;            // cycles into the current cell
  wire [7:0] row_byte = image[8 * row[0] +: 8];
  wire [7:0] bits_now = (p_now == 8'd0) ? row_byte :
                        (in_cell == CELL - 1) ? {bits[6:0], 1'b0} : bits;
  wire [2:0] cell = p_now / CELL;
  always @(posedge clk)
    if (rst_n && judged) begin
      bits <= bits_now;
      in_cell <= (p_now == 8'd0 || in_cell == CELL - 1) ? 8'd0 : in_cell + 8'd1;
    end
  wire want_px = in_window && bits_now[7];
  wire want_vs = !(judged && line_in_frame >= V_VISIBLE + V_FRONT &&
                   line_in_frame < V_VISIBLE + V_FRONT + V_SYNC);

  always @(*) begin
    if (rst_n && configured) begin
      assert(tx_pop[1] == 1'b0 && rx_push == 2'b00);
      assert(gpio_out[1] == px && gpio_out[2] == px && gpio_out[4] == px &&
             gpio_out[5] == px && gpio_out[6] == px);
      assert(gpio_oe == 8'hff);
      if (judged) assert(hs == !(p_now < SYNC));        // HSYNC: exactly SYNC low each line
      if (!judged) assert(hs);
      if (in_window) assert(seen[row[0]]);              // shown rows were read from SRAM
      assert(px_late == want_px);                        // every pixel, every cycle
      if (judged) assert(vs_late == want_vs);            // VSYNC lines
      cover(judged && k_now == FRAME && p_now == VISIBLE - 1);   // a frame and the next one's first line
      cover(in_window && row == 8'd1 && px_late && cell == 3'd7);
    end
  end
endmodule

`default_nettype wire
