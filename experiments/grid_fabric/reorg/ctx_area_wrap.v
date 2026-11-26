`default_nettype none
// Area wrapper: one cell's switch + sink selectors with their configuration
// flops, at C contexts (1 = today's switch and selectors; contexts >= C are
// unreachable: their configuration is tied off and next-context fields are
// limited to < C).
module ctx_area_wrap #(parameter C=1, NSINK=5)(
  input wire clk, run, cfg_we, input wire [5:0] cfg_addr, input wire [15:0] cfg_data,
  input wire [3:0] north_in, south_in, west_in, east_in, local_out,
  output wire [3:0] north_out, south_out, west_out, east_out,
  output wire [NSINK-1:0] sinks, output wire [1:0] ctx);
  localparam PER=48+5*NSINK+(C>1 ? 14 : 0);
  localparam W=((C*PER+15)/16)*16;
  reg [W-1:0] cfg;
  always @(posedge clk) if(cfg_we && cfg_addr<W/16) cfg[16*cfg_addr+:16]<=cfg_data;
  wire [4*48-1:0] tcfg; wire [4*NSINK*5-1:0] scfg; wire [4*14-1:0] xcfg;
  genvar c;
  generate for(c=0;c<4;c=c+1) begin: ctxs
    if(c<C) begin
      wire [PER-1:0] p=cfg[PER*c+:PER];
      assign tcfg[48*c+:48]=p[47:0];
      assign scfg[5*NSINK*c+:5*NSINK]=p[48+:5*NSINK];
      if(C>1) begin
        wire [13:0] x=p[48+5*NSINK+:14];
        assign xcfg[14*c+:14]={C>2 ? x[13] : 1'b0, x[12:7], C>2 ? x[6] : 1'b0, x[5:0]};
      end else assign xcfg[14*c+:14]=0;
    end else begin
      assign tcfg[48*c+:48]=0; assign scfg[5*NSINK*c+:5*NSINK]=0; assign xcfg[14*c+:14]=0;
    end
  end endgenerate
  ctx_switch #(.NSINK(NSINK)) sw(clk,run,north_in,south_in,west_in,east_in,local_out,
    tcfg,scfg,xcfg,north_out,south_out,west_out,east_out,sinks,ctx);
endmodule
`default_nettype wire
