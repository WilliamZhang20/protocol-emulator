`default_nettype none

// Programmable CRC datapath (protocol-neutral). Width 1..16 via CRC_SETUP,
// plus one-pulse IEEE-802.3 CRC-32 setup (width 32, poly 0x04C11DB7,
// init/xor ones, refin/refout). Reflect-in on feed, reflect-out/xor applied
// only when `finalize` pulses.
//
// Timing: byte feed and reflect-out finalize are bit-serial (one bit / clock)
// so the former 8-step combinational unroll cannot miss a 20 ns setup.
// `busy` stays high while a multi-cycle op runs; the VM / action engine stall.
module crc_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        setup,
    input  wire        setup32,
    input  wire [7:0]  cfg,
    input  wire [15:0] poly,
    input  wire        feed,
    input  wire [7:0]  feed_byte,
    input  wire        finalize,
    output reg  [31:0] crc,
    output wire        busy
);
  // cfg: {init_ones, xor_ones, refout, refin, width_m1[3:0]}
  wire [3:0] width_m1 = cfg[3:0];
  wire       init_ones = cfg[7];
  wire [4:0] width = {1'b0, width_m1} + 5'd1;
  wire [15:0] width_mask = (16'hFFFF >> (5'd16 - width));

  localparam [31:0] CRC32_POLY = 32'h04C11DB7;

  localparam ST_IDLE = 2'd0;
  localparam ST_FEED = 2'd1;
  localparam ST_EMIT = 2'd2;  // reflect-out bit emit + optional xor

  function automatic [7:0] rev8(input [7:0] v);
    integer i;
    begin
      for (i = 0; i < 8; i = i + 1)
        rev8[i] = v[7 - i];
    end
  endfunction

  reg [31:0] poly_r;
  // Persistent cfg bits: {xor_ones, refout, refin}.
  reg [2:0]  cfg_r;
  reg [5:0]  width_r;
  reg [31:0] width_mask_r;
  reg [5:0]  top_shift_r;
  reg [31:0] state;

  reg [1:0]  phase;
  reg [5:0]  bits_left;
  reg [7:0]  feed_shift;
  reg [31:0] fin_src;
  reg [31:0] fin_acc;

  wire start_feed = feed && (phase == ST_IDLE);
  wire start_fin  = finalize && (phase == ST_IDLE);
  // Busy tracks in-flight work only. Including the start strobe here deadlocks
  // the VM issue/wait handshake (feed requires !busy, which then asserts busy).
  assign busy = (phase != ST_IDLE);

  always @(posedge clk) begin
    if (!rst_n) begin
      crc <= 32'b0;
      state <= 32'b0;
      poly_r <= 32'b0;
      cfg_r <= 3'b0;
      width_r <= 6'b0;
      width_mask_r <= 32'b0;
      top_shift_r <= 6'b0;
      phase <= ST_IDLE;
      bits_left <= 6'b0;
      feed_shift <= 8'b0;
      fin_src <= 32'b0;
      fin_acc <= 32'b0;
    end else if (setup) begin
      cfg_r <= cfg[6:4];
      width_r <= {1'b0, width};
      width_mask_r <= {16'b0, width_mask};
      top_shift_r <= {1'b0, width} - 6'd1;
      poly_r <= {16'b0, poly & width_mask};
      state <= init_ones ? {16'b0, width_mask} : 32'b0;
      crc <= init_ones ? {16'b0, width_mask} : 32'b0;
      phase <= ST_IDLE;
    end else if (setup32) begin
      cfg_r <= 3'b111;
      width_r <= 6'd32;
      width_mask_r <= 32'hFFFFFFFF;
      top_shift_r <= 6'd31;
      poly_r <= CRC32_POLY;
      state <= 32'hFFFFFFFF;
      crc <= 32'hFFFFFFFF;
      phase <= ST_IDLE;
    end else begin
      case (phase)
        ST_FEED: begin
          begin : feed_bit
            reg [31:0] c;
            reg top;
            reg bit_in;
            c = state;
            bit_in = feed_shift[7];
            top = (|( (c >> top_shift_r) & 32'h00000001 )) ^ bit_in;
            c = ({c[30:0], 1'b0}) & width_mask_r;
            if (top)
              c = (c ^ poly_r) & width_mask_r;
            state <= c;
            crc <= c;
            feed_shift <= {feed_shift[6:0], 1'b0};
            if (bits_left == 6'd1)
              phase <= ST_IDLE;
            bits_left <= bits_left - 6'd1;
          end
        end
        ST_EMIT: begin
          begin : emit_bit
            reg bit_in;
            reg [31:0] next_acc;
            // LSB-first absorb bit-reverses the low `width` bits.
            bit_in = fin_src[0];
            next_acc = {fin_acc[30:0], bit_in};
            fin_acc <= next_acc;
            fin_src <= {1'b0, fin_src[31:1]};
            if (bits_left == 6'd1) begin
              crc <= (cfg_r[2] ? (next_acc ^ width_mask_r) : next_acc)
                  & width_mask_r;
              phase <= ST_IDLE;
            end
            bits_left <= bits_left - 6'd1;
          end
        end
        default: begin // ST_IDLE
          if (start_feed) begin
            feed_shift <= cfg_r[0] ? rev8(feed_byte) : feed_byte;
            bits_left <= 6'd8;
            phase <= ST_FEED;
          end else if (start_fin) begin
            if (!cfg_r[1]) begin
              crc <= (cfg_r[2] ? (state ^ width_mask_r) : state) & width_mask_r;
            end else begin
              fin_src <= state & width_mask_r;
              fin_acc <= 32'b0;
              bits_left <= width_r;
              phase <= ST_EMIT;
            end
          end
        end
      endcase
    end
  end
endmodule

`default_nettype wire
