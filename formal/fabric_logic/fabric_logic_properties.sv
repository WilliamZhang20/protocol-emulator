`default_nettype none

// Logic cell against a shadow configuration: the output register loads the
// truth-table entry the four selected inputs index exactly on enable-line
// cycles, holds otherwise, and holds the configured start value while the
// fabric is disabled. Both contexts are modelled:
// writes go to any set of contexts, the next context is chosen arbitrarily
// every cycle, and the cell always behaves as the active context says.
module fabric_logic_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [1:0]  cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [1:0]  cfg_bank;
  (* anyseq *) reg        ctx_next;
  reg        ctx = 1'b0;           // the active context
  (* anyseq *) reg [63:0] lines_any;
  wire [63:0] lines = {lines_any[63:2], 1'b1, 1'b0};
  wire q;

  fabric_logic dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .cfg_bank(cfg_bank), .ctx_next(ctx_next),
      .lines(lines), .q(q)
  );

  // Per context: {start, enable, in3, in2, in1, in0, truth}.
  reg [43:0] ctx_s [0:1];
  initial begin ctx_s[0] = 44'd0; ctx_s[1] = 44'd0; end
  reg        q_model = 1'b0;
  wire [43:0] active = ctx_s[ctx];
  wire [15:0] truth_s = active[15:0];
  wire [5:0]  in0_s = active[21:16], in1_s = active[27:22];
  wire [4:0]  in2_s = active[32:28], in3_s = active[37:33], en_s = active[42:38];
  wire        start_s = active[43];

  function automatic [43:0] written(input [43:0] c);
    begin
      written = c;
      case (cfg_addr)
        2'd0: written[15:0] = cfg_data;
        2'd1: written[27:16] = cfg_data[11:0];
        2'd2: written[37:28] = cfg_data[9:0];
        default: written[43:38] = cfg_data[5:0];
      endcase
    end
  endfunction

  wire [3:0] index = {lines[{1'b1, in3_s}], lines[{1'b1, in2_s}],
                      lines[in1_s], lines[in0_s]};
  wire f = truth_s[index];

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      ctx_s[0] <= 44'd0; ctx_s[1] <= 44'd0;
      ctx <= 1'b0;
      q_model <= 1'b0;
    end else begin
      ctx <= ctx_next;
      if (cfg_we && cfg_bank[0]) ctx_s[0] <= written(ctx_s[0]);
      if (cfg_we && cfg_bank[1]) ctx_s[1] <= written(ctx_s[1]);
      if (!enable)
        q_model <= start_s;
      else if (lines[{1'b0, en_s}])
        q_model <= f;
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(q == q_model);
      cover(q && enable && !lines[{1'b0, en_s}]);
      cover(start_s && q && !enable);
      cover(ctx && enable && lines[{1'b0, en_s}] && f != ctx_s[0][index]);
    end
  end
endmodule

`default_nettype wire
