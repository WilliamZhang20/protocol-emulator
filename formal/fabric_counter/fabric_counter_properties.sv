`default_nettype none

// Counter tile against a reference written per mode: event counting and the
// three run-length modes, saturation at 255, clear priority, the >= level,
// and a hit pulse exactly on the step that first reaches the threshold.
module fabric_counter_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg        enable;
  (* anyseq *) reg        cfg_we;
  (* anyseq *) reg [1:0]  cfg_addr;
  (* anyseq *) reg [12:0] cfg_data;
  (* anyseq *) reg [63:0] lines_any;
  wire [63:0] lines = {lines_any[63:2], 1'b1, 1'b0};
  wire ge, hit;
  wire [7:0] count;

  fabric_counter dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .cfg_bank(2'b01), .ctx_next(1'b0),       // contexts: checked in fabric_logic
      .lines(lines), .ge(ge), .hit(hit), .count(count)
  );

  reg [7:0]  match_s = 8'd0;
  reg [12:0] step_s = 13'd0;
  reg [4:0]  clear_s = 5'd0;
  reg [7:0]  r_count = 8'd0;
  reg        r_last = 1'b0;
  wire stepping = lines[step_s[5:0]];
  wire data = lines[{1'b1, step_s[10:6]}];
  wire clearing = lines[{1'b0, clear_s}];

  function automatic [7:0] bump(input [7:0] v);
    bump = v == 8'd255 ? 8'd255 : v + 8'd1;
  endfunction

  reg [7:0] r_next;
  always @(*) begin
    r_next = r_count;
    if (step_s[12:11] == 2'd0) r_next = bump(r_count);
    else if (step_s[12:11] == 2'd1) r_next = data ? bump(r_count) : 8'd0;
    else if (step_s[12:11] == 2'd2) r_next = data ? 8'd0 : bump(r_count);
    else r_next = (data == r_last) ? bump(r_count) : 8'd1;
  end

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n) begin
      match_s <= 8'd0; step_s <= 13'd0; clear_s <= 5'd0;
      r_count <= 8'd0; r_last <= 1'b0;
    end else begin
      if (cfg_we) begin
        case (cfg_addr)
          2'd0: match_s <= cfg_data[7:0];
          2'd1: step_s <= cfg_data;
          2'd2: clear_s <= cfg_data[4:0];
          default: begin end
        endcase
      end
      if (!enable) begin
        r_count <= 8'd0; r_last <= 1'b0;
      end else if (clearing) begin
        r_count <= 8'd0;
      end else if (stepping) begin
        r_count <= r_next; r_last <= data;
      end
    end
  end

  always @(*) begin
    if (rst_n) begin
      assert(count == r_count);
      assert(ge == (r_count >= match_s));
      assert(hit == (enable && !clearing && stepping &&
                     r_count < match_s && r_next >= match_s));
      cover(hit && step_s[12:11] == 2'd3 && match_s == 8'd5);
      cover(ge && count == 8'd6 && step_s[12:11] == 2'd1);
    end
  end
endmodule

`default_nettype wire
