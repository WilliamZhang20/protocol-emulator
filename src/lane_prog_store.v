`default_nettype none
// The lane controller's program store: one synchronous single-port
// 2**ABITS x 16 memory. Read (men, ren, !wen): dout is the word the clock
// after. Write (men, wen): the word is stored and dout holds. Otherwise dout
// holds. Contents and dout are not reset. On chip (USE_MACRO, ABITS 6) it is
// the IHP RM_IHPSG13_1P_64x16_c2 macro; the model below has the macro's
// cycle semantics (the vendor model, test/models, defines them; the
// lane-store test compares the two).
module lane_prog_store #(parameter ABITS=6,parameter USE_MACRO=0)(
  input wire clk,men,wen,ren,input wire [ABITS-1:0] addr,input wire [15:0] din,
  output wire [15:0] dout
`ifdef FORMAL
  ,output wire [(16<<ABITS)-1:0] dbg_words
`endif
  );
  generate if(USE_MACRO!=0 && ABITS==6) begin: macro
    (* keep *) RM_IHPSG13_1P_64x16_c2 sram(.A_CLK(clk),.A_MEN(men),.A_WEN(wen),.A_REN(ren),
      .A_ADDR(addr),.A_DIN(din),.A_DLY(1'b1),.A_DOUT(dout));
  end else begin: model
    reg [15:0] words [0:(1<<ABITS)-1];
    reg [15:0] data;
    always @(posedge clk)
      if(men) begin
        if(wen) words[addr]<=din;
        else if(ren) data<=words[addr];
      end
    assign dout=data;
`ifdef FORMAL
    genvar gi;
    for(gi=0;gi<(1<<ABITS);gi=gi+1) begin: dbg
      assign dbg_words[gi*16+:16]=words[gi];
    end
`endif
  end endgenerate
endmodule
`default_nettype wire
