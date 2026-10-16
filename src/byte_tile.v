`default_nettype none

// Byte-stream tile. The bit fabric turns wire activity into bytes; byte
// tiles work on those bytes between a shifter and its FIFO channel. A byte
// travels with two tags, eop (last byte of a packet) and err, and every
// link is a valid/ready handshake: a byte moves when both are high.
//
// The output is a one-byte register and in_ready depends only on registers,
// never on out_ready, so no handshake path crosses a tile combinationally.
// The price is half throughput (one byte every two cycles, where a
// two-entry skid buffer would manage one a cycle); the fastest serial byte
// here takes 32 cycles, so a skid buffer would only cost area.
//
// Registers (16-bit, written by the controller):
//   0 mode   [2:0] function (below)  [3] ESCAPE: append F after a packet
//            [4] ESCAPE: send F before a packet  [5] CHECK: xor (else add)
//            [6] CHECK: verify (else generate)
//   1 a      ESCAPE/UNESCAPE {c1, c0}; MATCH {mask, value};
//            CHECK [7:0] initial value; TAG [7:0] packet length (0: none)
//   2 b      ESCAPE/UNESCAPE {m1, m0}; TAG [5:0] end line, [11:6] error line
//   3 c      ESCAPE/UNESCAPE {F, E}
//
// Functions:
//   0 PASS      bytes and tags unchanged.
//   1 ESCAPE    c0 is sent as E m0 and c1 as E m1; optionally a packet is
//               framed by the delimiter F. Tags move to its last byte.
//   2 UNESCAPE  the inverse: F ends a packet (eop on the byte before it; a
//               packet ended inside an escape is flagged err), E m0 gives
//               c0, E m1 gives c1, E followed by anything else is flagged
//               err. Valid configurations have {c0, c1} = {F, E}.
//   3 TAG       packets from fabric events: a packet ends when the end
//               line fires (or after `length` bytes, or on an input eop),
//               and is flagged err if the error line was high during it.
//               The core feeds byte tiles the signal space one cycle late.
//   4 CHECK     8-bit add or xor checksum over each packet. Generate
//               appends the byte that makes the total zero (two's
//               complement for add), or a wrong one when the last byte
//               is tagged err (error injection); verify flags err on a
//               packet whose total, checksum included, is not zero.
//   5 MATCH     keeps packets whose first byte matches value under mask,
//               drops the rest.
// `event` pulses when a packet leaves the tile (MATCH: when one matches;
// CHECK verify: when one fails).
module byte_tile (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [63:0] lines,
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_eop,
    input  wire        in_err,
    output wire        in_ready,
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_eop,
    output wire        out_err,
    input  wire        out_ready,
    output wire        event_pulse
);
  localparam F_ESCAPE = 3'd1, F_UNESCAPE = 3'd2, F_TAG = 3'd3,
             F_CHECK = 3'd4, F_MATCH = 3'd5;
  // Bytes ESCAPE and CHECK still owe after the input byte that caused them.
  localparam P_NONE = 2'd0, P_SECOND = 2'd1, P_DELIM = 2'd2, P_SUM = 2'd3;

  reg [6:0]  mode;
  reg [15:0] reg_a, reg_b, reg_c;

  wire [2:0] fn       = mode[2:0];
  wire       append   = mode[3];
  wire       prepend  = mode[4];
  wire       use_xor  = mode[5];
  wire       verify   = mode[6];
  wire [7:0] c0 = reg_a[7:0], c1 = reg_a[15:8];
  wire [7:0] m0 = reg_b[7:0], m1 = reg_b[15:8];
  wire [7:0] esc = reg_c[7:0], delim = reg_c[15:8];

  reg        o_valid, o_eop, o_err;
  reg [7:0]  o_data;
  reg        h_valid, h_eop, h_err;     // UNESCAPE/TAG: the newest byte,
  reg [7:0]  h_data;                    // held until its packet's end is known
  reg [1:0]  pend;
  reg [7:0]  p_data;
  reg        p_eop, p_err;
  reg        sop;                       // the next input byte starts a packet
  reg        after_esc, drop, end_pend, err_seen;
  reg [7:0]  acc, count;
  reg        event_r;

  wire slot_free = !o_valid;
  wire end_line  = lines[reg_b[5:0]];
  wire err_line  = lines[reg_b[11:6]];

  reg ready;
  always @(*) begin
    case (fn)
      F_ESCAPE:   ready = slot_free && pend == P_NONE && !(prepend && sop);
      F_UNESCAPE: ready = slot_free && !(h_valid && h_eop);
      F_TAG:      ready = slot_free && !(h_valid && end_pend);
      F_CHECK:    ready = slot_free && pend == P_NONE;
      default:    ready = slot_free;
    endcase
  end
  wire take = in_valid && ready;

  wire        special  = in_data == c0 || in_data == c1;
  wire [7:0]  mapped   = in_data == c0 ? m0 : m1;
  wire        unmapped = in_data == m0 || in_data == m1;
  wire [7:0]  restored = in_data == m0 ? c0 : in_data == m1 ? c1 : in_data;
  wire [7:0]  acc_next = use_xor ? acc ^ in_data : acc + in_data;
  wire        hit      = ((in_data ^ reg_a[7:0]) & reg_a[15:8]) == 8'd0;
  wire        len_hit  = reg_a[7:0] != 8'd0 && count + 8'd1 == reg_a[7:0];

  assign in_ready    = ready;
  assign out_valid   = o_valid;
  assign out_data    = o_data;
  assign out_eop     = o_eop;
  assign out_err     = o_err;
  assign event_pulse = event_r;

  always @(posedge clk) begin
    if (!rst_n) begin
      mode  <= 7'd0;
      reg_a <= 16'd0;
      reg_b <= 16'd0;
      reg_c <= 16'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        2'd0: mode  <= cfg_data[6:0];
        2'd1: reg_a <= cfg_data;
        2'd2: reg_b <= cfg_data;
        default: reg_c <= cfg_data;
      endcase
    end
  end

  // emit(): load the output register (only ever called with the slot free).
  task automatic emit(input [7:0] d, input e, input r);
    begin
      o_valid <= 1'b1;
      o_data  <= d;
      o_eop   <= e;
      o_err   <= r;
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      o_valid <= 1'b0; o_data <= 8'd0; o_eop <= 1'b0; o_err <= 1'b0;
      h_valid <= 1'b0; h_data <= 8'd0; h_eop <= 1'b0; h_err <= 1'b0;
      pend <= P_NONE; p_data <= 8'd0; p_eop <= 1'b0; p_err <= 1'b0;
      sop <= 1'b1; after_esc <= 1'b0; drop <= 1'b0;
      end_pend <= 1'b0; err_seen <= 1'b0;
      acc <= 8'd0; count <= 8'd0; event_r <= 1'b0;
    end else begin
      event_r <= 1'b0;
      if (o_valid && out_ready)
        o_valid <= 1'b0;

      case (fn)
        F_ESCAPE: begin
          if (slot_free && pend == P_SECOND) begin
            if (append && p_eop) begin
              emit(p_data, 1'b0, 1'b0);
              pend <= P_DELIM;
            end else begin
              emit(p_data, p_eop, p_err);
              pend <= P_NONE;
              event_r <= p_eop;
            end
          end else if (slot_free && pend == P_DELIM) begin
            emit(delim, p_eop, p_err);
            pend <= P_NONE;
            event_r <= p_eop;
          end else if (slot_free && pend == P_NONE && prepend && sop && in_valid) begin
            emit(delim, 1'b0, 1'b0);
            sop <= 1'b0;
          end else if (take) begin
            sop   <= in_eop;
            p_eop <= in_eop;
            p_err <= in_err;
            if (special) begin
              emit(esc, 1'b0, 1'b0);
              p_data <= mapped;
              pend <= P_SECOND;
            end else if (append && in_eop) begin
              emit(in_data, 1'b0, 1'b0);
              pend <= P_DELIM;
            end else begin
              emit(in_data, in_eop, in_err);
              event_r <= in_eop;
            end
          end
        end

        F_UNESCAPE: begin
          if (slot_free && h_valid && h_eop) begin
            emit(h_data, 1'b1, h_err);
            h_valid <= 1'b0;
            event_r <= 1'b1;
          end else if (take) begin
            if (in_data == delim) begin
              if (h_valid) begin
                emit(h_data, 1'b1, h_err || in_err || after_esc);
                event_r <= 1'b1;
              end
              h_valid   <= 1'b0;
              after_esc <= 1'b0;
            end else if (in_data == esc && !after_esc) begin
              after_esc <= 1'b1;
            end else begin
              if (h_valid)
                emit(h_data, 1'b0, h_err);
              h_valid   <= 1'b1;
              h_data    <= after_esc ? restored : in_data;
              h_eop     <= in_eop;
              h_err     <= in_err || (after_esc && !unmapped);
              after_esc <= 1'b0;
            end
          end
        end

        F_TAG: begin
          if (slot_free && h_valid && end_pend) begin
            emit(h_data, 1'b1, h_err || err_seen);
            h_valid  <= 1'b0;
            end_pend <= 1'b0;
            err_seen <= 1'b0;
            count    <= 8'd0;
            event_r  <= 1'b1;
          end else begin
            if (take) begin
              if (h_valid)
                emit(h_data, 1'b0, h_err);
              h_valid <= 1'b1;
              h_data  <= in_data;
              h_err   <= in_err;
              count   <= len_hit ? 8'd0 : count + 8'd1;
            end
            if ((end_line && (h_valid || take)) || (take && (in_eop || len_hit)))
              end_pend <= 1'b1;
            if (err_line)
              err_seen <= 1'b1;
          end
        end

        F_CHECK: begin
          if (slot_free && pend == P_SUM) begin
            emit(p_data, 1'b1, p_err);
            pend <= P_NONE;
            event_r <= 1'b1;
          end else if (take) begin
            acc <= in_eop ? reg_a[7:0] : acc_next;
            if (verify) begin
              emit(in_data, in_eop, in_err || (in_eop && acc_next != 8'd0));
              event_r <= in_eop && acc_next != 8'd0;
            end else if (in_eop) begin
              // A last byte tagged err asks for a wrong checksum instead.
              emit(in_data, 1'b0, 1'b0);
              p_data <= (use_xor ? acc_next : 8'd0 - acc_next) ^ {8{in_err}};
              p_err  <= 1'b0;
              pend   <= P_SUM;
            end else begin
              emit(in_data, 1'b0, in_err);
            end
          end
        end

        F_MATCH: begin
          if (take) begin
            sop <= in_eop;
            if (sop ? hit : !drop)
              emit(in_data, in_eop, in_err);
            if (sop)
              event_r <= hit;
            drop <= in_eop ? 1'b0 : (sop ? !hit : drop);
          end
        end

        default: begin                  // PASS (and the unused codes 6, 7)
          if (take)
            emit(in_data, in_eop, in_err);
        end
      endcase
    end
  end
endmodule

`default_nettype wire
