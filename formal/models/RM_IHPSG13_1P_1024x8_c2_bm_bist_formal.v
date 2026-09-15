`default_nettype none

// Arbitrary-address abstraction of the foundry SRAM for formal verification.
// Because tracked_address is unconstrained and constant, proving its behavior
// proves the same masked-write/read property for every physical SRAM address.
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
  (* anyconst *) reg [9:0] tracked_address;
  (* anyseq *) reg [7:0] arbitrary_read_data;
  reg [7:0] tracked_data;
  reg tracked_valid = 1'b0;
  reg expected_pending = 1'b0;
  reg [7:0] expected_read;

  wire selected = A_MEN && A_ADDR == tracked_address;
  wire full_write = &A_BM;
  wire [7:0] merged_data = (tracked_data & ~A_BM) | (A_DIN & A_BM);
  wire [7:0] selected_write_data =
      tracked_valid ? merged_data : A_DIN;
  wire selected_read_known =
      selected && A_REN && (tracked_valid || (A_WEN && full_write));

  always @(posedge A_CLK) begin
    if (expected_pending)
      assert(A_DOUT == expected_read);

    expected_pending <= selected_read_known;
    if (selected_read_known)
      expected_read <= A_WEN ? selected_write_data : tracked_data;

    if (A_MEN && A_REN)
      A_DOUT <= selected_read_known
          ? (A_WEN ? selected_write_data : tracked_data)
          : arbitrary_read_data;

    if (selected && A_WEN) begin
      if (tracked_valid)
        tracked_data <= merged_data;
      else if (full_write) begin
        tracked_data <= A_DIN;
        tracked_valid <= 1'b1;
      end
    end

    cover(tracked_valid && expected_pending);
    cover(tracked_valid && selected && A_WEN &&
          A_BM != 8'h00 && A_BM != 8'hff);
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
