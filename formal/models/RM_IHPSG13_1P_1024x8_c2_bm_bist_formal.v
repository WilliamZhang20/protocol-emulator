`default_nettype none

module RM_IHPSG13_1P_1024x8_c2_bm_bist (
    input  wire       A_CLK,
    input  wire       A_MEN,
    input  wire       A_WEN,
    input  wire       A_REN,
    input  wire [9:0] A_ADDR,
    input  wire [7:0] A_DIN,
    input  wire       A_DLY,
    output reg  [7:0] A_DOUT,
    input  wire [7:0] A_BM,
    input  wire       A_BIST_CLK,
    input  wire       A_BIST_EN,
    input  wire       A_BIST_MEN,
    input  wire       A_BIST_WEN,
    input  wire       A_BIST_REN,
    input  wire [9:0] A_BIST_ADDR,
    input  wire [7:0] A_BIST_DIN,
    input  wire [7:0] A_BIST_BM
);

  reg [7:0] memory [0:1023];
  wire [7:0] write_value = (memory[A_ADDR] & ~A_BM) | (A_DIN & A_BM);

  always @(posedge A_CLK) begin
    if (A_MEN && A_WEN)
      memory[A_ADDR] <= write_value;

    if (A_MEN && A_REN)
      A_DOUT <= A_WEN ? write_value : memory[A_ADDR];
  end

  always @(*) begin
    assert(A_DLY);
    assert(!A_BIST_EN);
    assert(!A_BIST_MEN);
    assert(!A_BIST_WEN);
    assert(!A_BIST_REN);
    assert(!A_BIST_CLK);
    assert(A_BIST_ADDR == 10'b0);
    assert(A_BIST_DIN == 8'b0);
    assert(A_BIST_BM == 8'b0);
  end

endmodule

`default_nettype wire
