`default_nettype none
// Configuration storage for the mesh on a chip (FABRIC_REORG.md step 6.2).
// The compiler's configuration vector (mesh.v layout, `compiled/*.hex`) is
// written a byte at a time: byte b holds vector bits [8b, 8b+8). Only the
// bits the mesh can read are stored; the rest read 0:
//   - track and sink selectors of context 0, and of contexts 1-3 only in a
//     cell with 4 contexts (CTX4); transition rows only with 4 contexts;
//   - the tile field up to its kind's width (io 52, timer 64, shifter 96,
//     crc 128, counter 48 bits);
//   - the word network's 117 bits.
//
// LATCH=1: one latch per stored bit (cfg_latch), as an FPGA holds its
// configuration (LATCH=0: a flop with an enable per bit, the same staged
// write, for comparison in the physical flow):
// a flop with a write enable costs 67 um^2 per bit in this library (no flop
// without reset, no clock gate), a reset latch 27. A write is staged so
// every latch enable is glitch-free by construction:
//   clock 0  the write's byte address and data are registered (busy rises);
//   clock 1  `strobe` rises: the enable of exactly that byte's latches is
//            strobe AND a decode of the address registered a clock earlier;
//   clock 2  `strobe` falls (the latches close on the data, still held);
//   clock 3  busy falls: the next write may change address and data.
// The host (mesh_host) holds a write while busy. Storage is cleared by
// reset and by `clear` (registered first), and the host writes it only
// while the mesh is held, so the mesh loads its tile registers from a
// complete configuration when the hold is released.
module mesh_cfg #(parameter ROWS=3, COLS=5,
  parameter [2*ROWS*COLS-1:0] KINDS=30'd287029521,
  parameter [ROWS*COLS-1:0] CTX4=15'd10570,
  parameter [ROWS*COLS-1:0] CNT=0,
  parameter CELL_BITS=512, WNET_BITS=128,
  parameter CFG_BITS=ROWS*COLS*CELL_BITS+WNET_BITS,
  parameter ABITS=10,
  parameter LATCH=1)(       // 1: a reset latch per bit; 0: a flop with an enable per bit
  input wire clk, rst_n, clear,
  input wire we, input wire [ABITS-1:0] addr, input wire [7:0] data,
  output wire busy,
  output wire [CFG_BITS-1:0] cfg);
  localparam N=ROWS*COLS, IO=0, TIMER=1, SHIFTER=2, CRC=3, COUNTER=4;
  localparam NBYTES=(CFG_BITS+7)/8;

  // Is vector bit i read by the mesh? (Pure: parameters and its argument.)
  function used(input integer i);
    integer c, o, k, width;
    begin
      if(i >= N*CELL_BITS) used = i - N*CELL_BITS < 117;
      else begin
        c = i / CELL_BITS; o = i % CELL_BITS;
        k = CNT[c] ? COUNTER : {30'd0, KINDS[2*c+:2]};
        width = k==IO ? 52 : k==TIMER ? 64 : k==SHIFTER ? 96 : k==CRC ? 128 : 48;
        if(o < 192)      used = CTX4[c] || o < 48;                 // tracks: 48 bits per context
        else if(o < 312) used = CTX4[c] || o - 192 < 30;           // sinks: 30 bits per context
        else if(o < 368) used = CTX4[c];                           // transitions
        else             used = o - 368 < width;                   // tile
      end
    end
  endfunction
  function byte_used(input integer b);
    integer j;
    begin
      byte_used = 0;
      for(j=0;j<8;j=j+1) if(8*b+j < CFG_BITS && used(8*b+j)) byte_used = 1;
    end
  endfunction

  reg [ABITS-1:0] a_q; reg [7:0] d_q; reg staged, strobe, settle, clr_q;
  always @(posedge clk)
    if(!rst_n) begin a_q<=0; d_q<=0; staged<=0; strobe<=0; settle<=0; clr_q<=0; end
    else begin
      clr_q <= clear;
      if(we && !busy) begin a_q<=addr; d_q<=data; end
      staged <= we && !busy;
      strobe <= staged;
      settle <= strobe;
    end
  assign busy = staged || strobe || settle;
  wire rn = rst_n && !clr_q;

  genvar b, j;
  generate for(b=0;b<NBYTES;b=b+1) begin: by
    if(byte_used(b)) begin: s
      wire en = strobe && a_q == b;
      for(j=0;j<8;j=j+1) begin: bit_
        if(8*b+j < CFG_BITS) begin: in_range
          if(used(8*b+j) && LATCH) begin: l
            cfg_latch q(.d(d_q[j]), .en(en), .rn(rn), .q(cfg[8*b+j]));
          end else if(used(8*b+j)) begin: f
            reg q;
            always @(posedge clk) if(!rn) q<=1'b0; else if(en) q<=d_q[j];
            assign cfg[8*b+j]=q;
          end else begin: z
            assign cfg[8*b+j]=1'b0;
          end
        end
      end
    end else begin: z
      for(j=0;j<8;j=j+1) begin: bit_
        if(8*b+j < CFG_BITS) begin: in_range
          assign cfg[8*b+j]=1'b0;
        end
      end
    end
  end endgenerate
endmodule

// One configuration bit: the IHP reset latch in synthesis, its behaviour in
// simulation (transparent while en, cleared while !rn).
module cfg_latch(input wire d, en, rn, output wire q);
`ifdef SYNTHESIS
  sg13cmos5l_dlhrq_1 u(.D(d), .GATE(en), .RESET_B(rn), .Q(q));
`else
  reg l;
  /* verilator lint_off LATCH */
  always @* if(!rn) l = 1'b0; else if(en) l = d;
  /* verilator lint_on LATCH */
  assign q = l;
`endif
endmodule
`default_nettype wire
