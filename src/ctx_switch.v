`default_nettype none
// Contexted switch (FABRIC_REORG.md, Active plan: control in the
// interconnect). Today's grid_switch track selection and the cell's sink
// selection, each held in C contexts, plus a local context state that
// changes on events arriving at this switch. A protocol phase is a routing
// context; a condition is whether a route exists in the current context.
//
// Track selector (3 bits, as grid_switch): 0 zero, 1-4 local output 0-3,
// 5 straight, 6/7 turn (tracks 0-1 turn horizontal-then-vertical only,
// 2-3 vertical-then-horizontal only).
// Sink selector (5 bits, as grid_core route_input): 0 zero, 1 one,
// 2-5 local 0-3, 6-9 north tracks, 10-13 south, 14-17 west, 18-21 east.
// Transition (per context, two rows of {event select[4:0], next[1:0]};
// event select uses the sink-selector space): if row A's event is high go to
// A's next, else if row B's go to B's next, else stay. Context 0 while not
// running. `ctx` is visible for tests.
// DSLOTS (FABRIC_REORG.md O3, static/dynamic split): 0, every selector held
// per context; D > 0, every selector held once (context 0's fields) plus D
// dynamic slots in track_cfg[48 +: 20 D], slot s = {value in context 3,
// 2, 1 [5 each], index[4:0]}: index 1-16 track selector index-1 (12 bits
// per direction, 3 per track, as context 0), 17-22 sink index-17, 0 none.
// In context k > 0 a selector named by a slot reads the slot's value (a
// track the low 3 bits; the lowest matching slot wins), any other its
// static value.
// CTX_TRACKS (with DSLOTS=0; FABRIC_REORG.md O3, the fixed split): a mask of
// the track indices whose selectors are held per context; the others read
// context 0's selector in every context. Sinks are held per context.
module ctx_switch #(parameter NSINK=4, DSLOTS=0, parameter [3:0] CTX_TRACKS=4'b1111)(
  input wire clk, run,
  input wire [3:0] north_in, south_in, west_in, east_in, local_out,
  input wire [4*48-1:0] track_cfg,          // context c: [48c+:48] = {east,west,south,north}[12 each]
  input wire [4*NSINK*5-1:0] sink_cfg,       // context c: [5*NSINK*c+:5*NSINK]
  input wire [4*14-1:0] trans_cfg,           // context c: [14c+:14] = {B next[13:12], B ev[11:7], A next[6:5], A ev[4:0]}
  output wire [3:0] north_out, south_out, west_out, east_out,
  output wire [NSINK-1:0] sinks,
  output reg [1:0] ctx);
  // The current context's rows: a 4-way choice between constant slices (no
  // run-time part-select base: tools/check_part_selects.py).
  localparam SW=5*NSINK;
  wire [47:0] tc; wire [SW-1:0] sc;
  genvar t, k, q;
  if(DSLOTS==0) begin: full
    wire [47:0] tcx = ctx==2'd0 ? track_cfg[0+:48] : ctx==2'd1 ? track_cfg[48+:48] : ctx==2'd2 ? track_cfg[96+:48] : track_cfg[144+:48];
    for(t=0;t<16;t=t+1) begin: tm
      assign tc[3*t+:3] = CTX_TRACKS[t%4] ? tcx[3*t+:3] : track_cfg[3*t+:3];
    end
    assign sc = ctx==2'd0 ? sink_cfg[0+:SW] : ctx==2'd1 ? sink_cfg[SW+:SW] : ctx==2'd2 ? sink_cfg[2*SW+:SW] : sink_cfg[3*SW+:SW];
  end else begin: split
    // Each slot's index and its value in the current context (0 outside
    // contexts 1-3, where no slot applies).
    wire [4:0] idx[0:DSLOTS-1], val[0:DSLOTS-1];
    for(q=0;q<DSLOTS;q=q+1) begin: sl
      wire [19:0] w=track_cfg[48+20*q+:20];
      assign idx[q]= ctx==2'd0 ? 5'd0 : w[4:0];
      assign val[q]= ctx==2'd1 ? w[9:5] : ctx==2'd2 ? w[14:10] : w[19:15];
    end
    // Selector i (1-based): a chain from the highest slot down, so the
    // lowest slot naming it wins; the end of the chain is the static value.
    for(t=0;t<16+NSINK;t=t+1) begin: sel_
      wire [4:0] ch[0:DSLOTS];
      if(t<16) begin: trk
        assign ch[DSLOTS]={2'b0,track_cfg[3*t+:3]};
        assign tc[3*t+:3]=ch[0][2:0];
      end else begin: snk
        assign ch[DSLOTS]=sink_cfg[5*(t-16)+:5];
        assign sc[5*(t-16)+:5]=ch[0];
      end
      for(k=0;k<DSLOTS;k=k+1) begin: hop
        assign ch[k]= idx[k]==t+1 ? val[k] : ch[k+1];
      end
    end
  end
  wire [13:0] xc = ctx==2'd0 ? trans_cfg[0+:14] : ctx==2'd1 ? trans_cfg[14+:14] : ctx==2'd2 ? trans_cfg[28+:14] : trans_cfg[42+:14];
  function automatic pick;
    input [2:0] s; input [3:0] l; input straight, turn_a, turn_b, allow;
    case(s)
      1:pick=l[0]; 2:pick=l[1]; 3:pick=l[2]; 4:pick=l[3];
      5:pick=straight; 6:pick=allow && turn_a; 7:pick=allow && turn_b; default:pick=1'b0;
    endcase
  endfunction
  function automatic sel;
    input [4:0] c; input [3:0] l, n, s, w, e;
    if(c==0) sel=0; else if(c==1) sel=1;
    else if(c<6) sel=l[c-2]; else if(c<10) sel=n[c-6]; else if(c<14) sel=s[c-10];
    else if(c<18) sel=w[c-14]; else if(c<22) sel=e[c-18]; else sel=0;
  endfunction
  generate for(t=0;t<4;t=t+1) begin: tracks
    assign north_out[t]=pick(tc[t*3+:3],local_out,south_in[t],west_in[t],east_in[t],t<2);
    assign south_out[t]=pick(tc[12+t*3+:3],local_out,north_in[t],west_in[t],east_in[t],t<2);
    assign west_out[t]=pick(tc[24+t*3+:3],local_out,east_in[t],north_in[t],south_in[t],t>=2);
    assign east_out[t]=pick(tc[36+t*3+:3],local_out,west_in[t],north_in[t],south_in[t],t>=2);
  end endgenerate
  generate for(k=0;k<NSINK;k=k+1) begin: sk
    assign sinks[k]=sel(sc[5*k+:5],local_out,north_in,south_in,west_in,east_in);
  end endgenerate
  wire ev_a=sel(xc[4:0],local_out,north_in,south_in,west_in,east_in);
  wire ev_b=sel(xc[11:7],local_out,north_in,south_in,west_in,east_in);
  always @(posedge clk)
    if(!run) ctx<=0;
    else if(ev_a) ctx<=xc[6:5];
    else if(ev_b) ctx<=xc[13:12];
endmodule
`default_nettype wire
