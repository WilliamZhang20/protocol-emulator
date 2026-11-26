`default_nettype none

// Lane core configuration validity (formal/grid_lane_core). The defined
// line set and the selector and reserved fields below are the contract's
// lane_core table (tools/check_grid_contract.py checks that they match it);
// the proof shows the core never reports a configuration valid while any
// selector names an undefined line or any reserved bit is set. Validity is
// combinational over the configuration words, so k-induction covers every
// word state, reachable or not; arbitrary writes drive the base case.
module grid_lane_core_properties (input wire clk);
  reg [1:0] t = 2'd0;
  always @(posedge clk) if (t != 2'd3) t <= t + 2'd1;
  wire rst_n = t != 2'd0;

  (* anyseq *) reg cfg_we, arm, start, abort, mem_ready, mem_rvalid, rd_valid, wr_ready;
  (* anyseq *) reg [5:0] cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [7:0] mem_rdata, rd_data;
  (* anyseq *) reg [1:0] pad_in, mesh_in;
  (* anyseq *) reg [47:0] fabric_readback;

  wire configured, mem_req, owns_port, resp_pending, rd_consume, rd_want, wr_valid, stream_fault;
  wire active, loading, done, error;
  wire [9:0] mem_addr;
  wire [7:0] wr_data;
  wire [2:0] out_value, out_enable;
  wire [38*16-1:0] f_words;
  grid_lane_core dut(.clk(clk), .rst_n(rst_n), .arm(arm), .cfg_we(cfg_we), .cfg_addr(cfg_addr),
      .cfg_data(cfg_data), .configured(configured), .start(start), .abort(abort),
      .mem_req(mem_req), .mem_ready(mem_ready), .mem_addr(mem_addr), .mem_rvalid(mem_rvalid),
      .mem_rdata(mem_rdata), .owns_port(owns_port), .resp_pending(resp_pending),
      .rd_valid(rd_valid), .rd_data(rd_data), .rd_consume(rd_consume), .rd_want(rd_want),
      .wr_valid(wr_valid), .wr_data(wr_data), .wr_ready(wr_ready), .stream_fault(stream_fault),
      .pad_in(pad_in), .mesh_in(mesh_in), .out_value(out_value), .out_enable(out_enable),
      .fabric_readback(fabric_readback), .active(active), .loading(loading), .done(done),
      .error(error), .f_words(f_words));

  // Defined lines (contract lane_core.lines), bit i set when line i exists.
  localparam [63:0] DEFINED = 64'h0007ffff0007ffff;
  wire [31:0] defined_levels = DEFINED[63:32];

`define FIELD(W, HI, LO) f_words[16*(W)+(HI):16*(W)+(LO)]
`define SEL_LINE(NAME, W, HI, LO) assert (DEFINED[`FIELD(W, HI, LO)]);
`define SEL_LEVEL(NAME, W, HI, LO) assert (defined_levels[`FIELD(W, HI, LO)]);
`define SEL_PULSE5(NAME, W, HI, LO) assert (DEFINED[{1'b0, `FIELD(W, HI, LO)}]);
`define RESERVED(W, HI, LO) assert (`FIELD(W, HI, LO) == 0);

  always @(*) if (rst_n && configured) begin
    `SEL_LINE(timer0.start, 8, 5, 0)
    `SEL_LINE(timer0.stop, 8, 11, 6)
    `SEL_LINE(timer0.aux, 9, 5, 0)
    `SEL_LINE(timer1.start, 9, 11, 6)
    `SEL_LINE(timer1.stop, 10, 5, 0)
    `SEL_LINE(timer1.aux, 10, 11, 6)
    `SEL_LINE(event0, 25, 5, 0)
    `SEL_LINE(event1, 25, 11, 6)
    `SEL_LINE(event2, 26, 5, 0)
    `SEL_LINE(event3, 26, 11, 6)
    `SEL_LINE(event4, 27, 5, 0)
    `SEL_LINE(event5, 27, 11, 6)
    `SEL_LINE(event6, 28, 5, 0)
    `SEL_LINE(event7, 28, 11, 6)
    `SEL_LINE(level0, 29, 5, 0)
    `SEL_LINE(level1, 29, 11, 6)
    `SEL_LINE(level2, 30, 5, 0)
    `SEL_LINE(level3, 30, 11, 6)
    `SEL_LINE(level4, 31, 5, 0)
    `SEL_LINE(level5, 31, 11, 6)
    `SEL_LINE(level6, 32, 5, 0)
    `SEL_LINE(level7, 32, 11, 6)
    `SEL_LINE(out0.value, 33, 5, 0)
    `SEL_LINE(out0.enable, 33, 11, 6)
    `SEL_LINE(out1.value, 34, 5, 0)
    `SEL_LINE(out1.enable, 34, 11, 6)
    `SEL_LINE(out2.value, 35, 5, 0)
    `SEL_LINE(out2.enable, 35, 11, 6)
    `SEL_LINE(coder.shift, 12, 5, 0)
    `SEL_LINE(coder.sample, 12, 11, 6)
    `SEL_LINE(coder.start, 13, 5, 0)
    `SEL_LEVEL(coder.in, 13, 10, 6)
    `SEL_LEVEL(coder.burst_end, 14, 4, 0)
    `SEL_LINE(coder.abort, 14, 12, 7)
    `SEL_LEVEL(coder.stuff_gate, 16, 4, 0)
    `SEL_LINE(crc.absorb, 21, 5, 0)
    `SEL_LEVEL(crc.data, 21, 10, 6)
    `SEL_LINE(crc.emit, 22, 5, 0)
    `SEL_PULSE5(crc.init, 22, 10, 6)
    `SEL_LEVEL(crc.absorb_gate, 24, 4, 0)
    `SEL_LEVEL(crc.emit_gate, 24, 10, 6)
    `RESERVED(8, 15, 12)
    `RESERVED(9, 15, 12)
    `RESERVED(10, 15, 12)
    `RESERVED(12, 15, 12)
    `RESERVED(13, 15, 13)
    `RESERVED(14, 15, 13)
    `RESERVED(16, 15, 13)
    `RESERVED(21, 15, 11)
    `RESERVED(22, 15, 11)
    `RESERVED(23, 15, 10)
    `RESERVED(24, 15, 12)
    `RESERVED(25, 15, 12)
    `RESERVED(26, 15, 12)
    `RESERVED(27, 15, 12)
    `RESERVED(28, 15, 12)
    `RESERVED(29, 15, 12)
    `RESERVED(30, 15, 12)
    `RESERVED(31, 15, 12)
    `RESERVED(32, 15, 12)
    `RESERVED(33, 15, 12)
    `RESERVED(34, 15, 12)
    `RESERVED(35, 15, 12)
    `RESERVED(37, 15, 8)
    `RESERVED(37, 3, 0)
  end

  // A valid configuration that uses lines from every group exists.
  always @(*) if (rst_n) begin
    cover (configured && `FIELD(33, 5, 0) == 6'd42 && `FIELD(25, 5, 0) == 6'd10 &&
           `FIELD(8, 5, 0) == 6'd12 && `FIELD(29, 11, 6) == 6'd50);
  end
endmodule

`default_nettype wire
