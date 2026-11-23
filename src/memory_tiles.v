`default_nettype none

// One synchronous, single-port 1024 x 8 bank. A read accepted at a rising
// edge returns data and valid during the following cycle. Writes acknowledge
// at acceptance and do not produce a response. Memory contents are not reset.
module experiment_memory_bank #(parameter USE_MACRO = 0)(
    input wire clk, input wire enable, input wire write_enable,
    input wire [9:0] address, input wire [7:0] write_data,
    output wire [7:0] read_data);
  generate if (USE_MACRO != 0) begin : macro_bank
    program_memory memory(clk, enable, write_enable, !write_enable,
                          address, write_data, 8'hff, read_data);
  end else begin : model_bank
    reg [7:0] words [0:1023];
    reg [7:0] data;
    always @(posedge clk)
      if (enable) begin
        if (write_enable) words[address] <= write_data;
        else data <= words[address];
      end
    assign read_data = data;
  end endgenerate
endmodule

// Two independent banks and two requesters. Each requester's configured route
// selects a bank; changing routes is allowed only while disarmed. Within a
// bank, round-robin arbitration accepts one request per cycle. Requests must
// remain asserted with stable payload until ready. Reads return rvalid/rdata
// in the cycle following acceptance, without response backpressure.
module experiment_memory_fabric #(parameter USE_MACRO = 0)(
    input wire clk, input wire rst_n, input wire arm,
    input wire cfg_we, input wire [1:0] cfg_routes,
    input wire [1:0] req, input wire [1:0] we,
    input wire [19:0] addr, input wire [15:0] wdata,
    output wire [1:0] ready, output wire [1:0] rvalid,
    output wire [15:0] rdata);
  reg [1:0] routes;
  reg [1:0] next_priority;
  reg [1:0] valid0, valid1;
  wire [1:0] grant0, grant1;
  wire [7:0] data0, data1;
  wire [1:0] candidates0 = req & {2{arm && rst_n}} & ~routes;
  wire [1:0] candidates1 = req & {2{arm && rst_n}} & routes;
  assign grant0 = candidates0 == 2'b11 ? (next_priority[0] ? 2'b10 : 2'b01) : candidates0;
  assign grant1 = candidates1 == 2'b11 ? (next_priority[1] ? 2'b10 : 2'b01) : candidates1;
  assign ready = grant0 | grant1;
  assign rvalid = valid0 | valid1;
  assign rdata[7:0] = valid1[0] ? data1 : data0;
  assign rdata[15:8] = valid1[1] ? data1 : data0;
  wire sel0 = grant0[1], sel1 = grant1[1];
  wire wr0 = |(grant0 & we), wr1 = |(grant1 & we);
  experiment_memory_bank #(.USE_MACRO(USE_MACRO)) bank0(
      clk, |grant0, wr0, sel0 ? addr[19:10] : addr[9:0],
      sel0 ? wdata[15:8] : wdata[7:0], data0);
  experiment_memory_bank #(.USE_MACRO(USE_MACRO)) bank1(
      clk, |grant1, wr1, sel1 ? addr[19:10] : addr[9:0],
      sel1 ? wdata[15:8] : wdata[7:0], data1);
  always @(posedge clk) begin
    if (!rst_n) begin
      routes <= 0; next_priority <= 0; valid0 <= 0; valid1 <= 0;
    end else begin
      if (!arm && cfg_we) routes <= cfg_routes;
      valid0 <= grant0 & ~we;
      valid1 <= grant1 & ~we;
      if (|grant0) next_priority[0] <= grant0[0];
      if (|grant1) next_priority[1] <= grant1[0];
    end
  end
endmodule
`default_nettype wire
