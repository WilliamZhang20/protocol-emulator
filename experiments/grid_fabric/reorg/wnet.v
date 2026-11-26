`default_nettype none
// Prototype (FABRIC_REORG.md step 2, word processing): word-path stages as
// independently assignable resources on a word network with valid/ready
// flow control. Every channel is {data[15:0], valid, ready}; a word moves
// when valid && ready.
//
// Sources (select value): 0 none, 1 reader, 2 shifter rx, 3 shifter status,
// 4 timer capture, 5 escape.out, 6 compare.out, 7 gate.out, 8 split.out,
// 9 interleave.out. Sinks (select index): 0 writer, 1 shifter tx,
// 2 escape.in, 3 compare.in, 4 gate.in, 5 split.in, 6 interleave.a,
// 7 interleave.b. Each sink's 4-bit select picks its source from that
// sink's reach list (REACH, below: not all-to-all); a source may feed at
// most one sink. `valid_config` is low for a source outside the reach
// list or used twice, so a word is never duplicated or lost. Every stage registers its
// output and its input ready depends only on its own registers, so no
// selection can close a combinational loop.
module wnet(
  input wire clk, rst_n,
  input wire [31:0] sel,                  // 8 sinks x 4 bits
  input wire [7:0] esc_match0, esc_match1, esc_byte, esc_repl0, esc_repl1,
  input wire [15:0] cmp_value, cmp_mask,
  input wire gate_open,                   // bit from the mesh
  output wire cmp_match,                  // bit onto the mesh
  input wire split_msb_first,
  // External endpoints.
  input wire [15:0] rd_data, input wire rd_valid, output wire rd_ready,
  input wire [15:0] rx_data, input wire rx_valid, output wire rx_ready,
  input wire [15:0] st_data, input wire st_valid, output wire st_ready,
  input wire [15:0] cap_data, input wire cap_valid, output wire cap_ready,
  output wire [15:0] wr_data, output wire wr_valid, input wire wr_ready,
  output wire [15:0] tx_data, output wire tx_valid, input wire tx_ready,
  output wire valid_config);
  localparam NSRC=10, NSINK=8;
  // Reach lists (bit = source), from the shipped programs
  // (FABRIC_REORG.md step 2): writer <- rx, capture, compare, gate, split,
  // interleave; tx <- reader, escape, compare; escape <- reader;
  // compare <- rx, reader, escape; gate <- rx, compare; split <- capture, rx;
  // interleave.a <- rx, compare, gate; interleave.b <- status.
  localparam [NSRC-1:0] R_WR =10'b1111010100, R_TX =10'b0001100010,
                        R_ESC=10'b0000000010, R_CMP=10'b0000100110,
                        R_GATE=10'b0001000100, R_SPL=10'b0000010100,
                        R_ILA=10'b0011000100, R_ILB=10'b0000001000;
  wire [NSRC-1:0] reach[0:NSINK-1];
  assign reach[0]=R_WR; assign reach[1]=R_TX; assign reach[2]=R_ESC; assign reach[3]=R_CMP;
  assign reach[4]=R_GATE; assign reach[5]=R_SPL; assign reach[6]=R_ILA; assign reach[7]=R_ILB;
  wire [15:0] sd[0:NSRC-1]; wire [NSRC-1:0] sv; wire [NSRC-1:0] sr;
  wire [15:0] kd[0:NSINK-1]; wire [NSINK-1:0] kv; wire [NSINK-1:0] kr;
  assign sd[0]=0; assign sv[0]=0;
  assign sd[1]=rd_data; assign sv[1]=rd_valid; assign rd_ready=sr[1];
  assign sd[2]=rx_data; assign sv[2]=rx_valid; assign rx_ready=sr[2];
  assign sd[3]=st_data; assign sv[3]=st_valid; assign st_ready=sr[3];
  assign sd[4]=cap_data; assign sv[4]=cap_valid; assign cap_ready=sr[4];
  genvar k, s;
  generate for(k=0;k<NSINK;k=k+1) begin: sinks
    wire [3:0] pick=sel[4*k+:4];
    assign kd[k]=pick<NSRC ? sd[pick] : 16'd0;
    assign kv[k]=pick<NSRC && pick!=0 && sv[pick] && valid_config;
  end endgenerate
  // A source's ready is its (single) sink's ready.
  generate for(s=0;s<NSRC;s=s+1) begin: sources
    wire [NSINK-1:0] mine;
    for(k=0;k<NSINK;k=k+1) begin: m
      assign mine[k]=sel[4*k+:4]==s;
    end
    assign sr[s]=s!=0 && valid_config && |(mine & kr);
  end endgenerate
  // Validity: selects in range, each nonzero source used at most once.
  reg ok; integer a, b;
  always @* begin
    ok=1;
    for(a=0;a<NSINK;a=a+1) begin
      if(sel[4*a+:4]>=NSRC) ok=0;
      else if(sel[4*a+:4]!=0 && !reach[a][sel[4*a+:4]]) ok=0;
      for(b=a+1;b<NSINK;b=b+1)
        if(sel[4*a+:4]!=0 && sel[4*a+:4]==sel[4*b+:4]) ok=0;
    end
  end
  assign valid_config=ok;
  assign wr_data=kd[0]; assign wr_valid=kv[0]; assign kr[0]=wr_ready;
  assign tx_data=kd[1]; assign tx_valid=kv[1]; assign kr[1]=tx_ready;

  // Escape (SLIP, HDLC): a byte equal to match0/match1 becomes the pair
  // {esc_byte, repl0/repl1}; any other byte passes.
  reg [15:0] e_q; reg e_v, e_pend; reg [7:0] e_second;
  assign kr[2]=!e_v && !e_pend;
  wire e_take=kv[2] && kr[2];
  wire e_hit0=kd[2][7:0]==esc_match0, e_hit1=kd[2][7:0]==esc_match1;
  always @(posedge clk) begin
    if(!rst_n) begin e_v<=0;e_pend<=0;end
    else begin
      if(e_v && sr[5]) begin
        if(e_pend) begin e_q<={8'd0,e_second};e_pend<=0;end else e_v<=0;
      end
      if(e_take) begin
        e_v<=1;
        if(e_hit0 || e_hit1) begin e_q<={8'd0,esc_byte};e_second<=e_hit0 ? esc_repl0 : esc_repl1;e_pend<=1;end
        else e_q<=kd[2];
      end
    end
  end
  assign sd[5]=e_q; assign sv[5]=e_v;

  // Compare: passes every word; `match` is ((word ^ value) & mask) == 0 for
  // the last word taken, held until the next.
  reg [15:0] c_q; reg c_v, c_m;
  assign kr[3]=!c_v;
  always @(posedge clk) begin
    if(!rst_n) begin c_v<=0;c_m<=0;end
    else begin
      if(c_v && sr[6]) c_v<=0;
      if(kv[3] && kr[3]) begin c_q<=kd[3];c_v<=1;c_m<=((kd[3]^cmp_value)&cmp_mask)==0;end
    end
  end
  assign sd[6]=c_q; assign sv[6]=c_v; assign cmp_match=c_m;

  // Gate: a word taken while the gate bit is high passes, otherwise it is
  // consumed and dropped.
  reg [15:0] g_q; reg g_v;
  assign kr[4]=!g_v;
  always @(posedge clk) begin
    if(!rst_n) g_v<=0;
    else begin
      if(g_v && sr[7]) g_v<=0;
      if(kv[4] && kr[4] && gate_open) begin g_q<=kd[4];g_v<=1;end
    end
  end
  assign sd[7]=g_q; assign sv[7]=g_v;

  // Split: a 16-bit word becomes two bytes (low first, or high first).
  reg [7:0] p_hold; reg [15:0] p_q; reg p_v, p_pend;
  assign kr[5]=!p_v && !p_pend;
  always @(posedge clk) begin
    if(!rst_n) begin p_v<=0;p_pend<=0;end
    else begin
      if(p_v && sr[8]) begin
        if(p_pend) begin p_q<={8'd0,p_hold};p_pend<=0;end else p_v<=0;
      end
      if(kv[5] && kr[5]) begin
        p_v<=1;p_pend<=1;
        p_q<={8'd0,split_msb_first ? kd[5][15:8] : kd[5][7:0]};
        p_hold<=split_msb_first ? kd[5][7:0] : kd[5][15:8];
      end
    end
  end
  assign sd[8]=p_q; assign sv[8]=p_v;

  // Interleave: one word from a, then one from b, repeating (a tag after
  // each byte).
  reg [15:0] i_q; reg i_v, i_turn;
  assign kr[6]=!i_v && !i_turn;
  assign kr[7]=!i_v && i_turn;
  always @(posedge clk) begin
    if(!rst_n) begin i_v<=0;i_turn<=0;end
    else begin
      if(i_v && sr[9]) i_v<=0;
      if(kv[6] && kr[6]) begin i_q<=kd[6];i_v<=1;i_turn<=1;end
      else if(kv[7] && kr[7]) begin i_q<=kd[7];i_v<=1;i_turn<=0;end
    end
  end
  assign sd[9]=i_q; assign sv[9]=i_v;
endmodule
`default_nettype wire
