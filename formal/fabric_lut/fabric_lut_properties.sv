`default_nettype none

// Glue cell against a shadow configuration: the combinational output is the
// truth-table entry the four selected inputs index, and the registered
// output loads that entry exactly on enable-line cycles, holds otherwise,
// and clears while the fabric is disabled.
module fabric_lut_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [1:0]  cfg_addr;
  (* anyseq *) reg [15:0] cfg_data;
  (* anyseq *) reg [63:0] lines_any;
  wire [63:0] lines = {lines_any[63:2], 1'b1, 1'b0};
  wire out, q;

  fabric_lut dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .lines(lines), .out(out), .q(q)
  );

  reg [15:0] truth_s = 16'd0;
  reg [5:0]  in0_s = 6'd0, in1_s = 6'd0;
  reg [4:0]  in2_s = 5'd0, in3_s = 5'd0, en_s = 5'd0;
  reg        registered_s = 1'b0;
  reg        q_model = 1'b0;

  wire [3:0] index = {lines[{1'b1, in3_s}], lines[{1'b1, in2_s}],
                      lines[in1_s], lines[in0_s]};
  wire f = truth_s[index];

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      truth_s <= 16'd0; in0_s <= 6'd0; in1_s <= 6'd0;
      in2_s <= 5'd0; in3_s <= 5'd0; en_s <= 5'd0; registered_s <= 1'b0;
      q_model <= 1'b0;
    end else begin
      if (cfg_we) begin
        case (cfg_addr)
          2'd0: truth_s <= cfg_data;
          2'd1: begin in0_s <= cfg_data[5:0]; in1_s <= cfg_data[11:6]; end
          2'd2: begin in2_s <= cfg_data[4:0]; in3_s <= cfg_data[9:5]; end
          default: begin en_s <= cfg_data[4:0]; registered_s <= cfg_data[5]; end
        endcase
      end
      if (!enable)
        q_model <= 1'b0;
      else if (lines[{1'b0, en_s}])
        q_model <= f;
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(q == q_model);
      assert(out == (registered_s ? q_model : f));
      cover(registered_s && q && enable && !lines[{1'b0, en_s}]);
      cover(!registered_s && out && index == 4'b1010);
    end
  end
endmodule

`default_nettype wire
