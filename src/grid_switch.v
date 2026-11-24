`default_nettype none
// Four independent tracks per directed edge. Horizontal routes can only
// continue straight; vertical routes may also turn from either horizontal
// input. No U-turn is possible, so even arbitrary selector settings cannot
// create a combinational routing cycle.
module grid_switch(
  input wire [3:0] north_in, south_in, west_in, east_in,
  input wire [3:0] local_out,
  input wire [11:0] north_cfg, south_cfg, west_cfg, east_cfg,
  output wire [3:0] north_out, south_out, west_out, east_out);
  genvar t;
  generate for(t=0;t<4;t=t+1) begin: tracks
    function automatic pick;
      input [2:0] s; input [3:0] local_bits;
      input straight, from_west, from_east; input vertical;
      begin
        case(s)
          1:pick=local_bits[0]; 2:pick=local_bits[1];
          3:pick=local_bits[2]; 4:pick=local_bits[3];
          5:pick=straight; 6:pick=vertical && from_west;
          7:pick=vertical && from_east; default:pick=1'b0;
        endcase
      end
    endfunction
    assign north_out[t]=pick(north_cfg[t*3+:3],local_out,south_in[t],west_in[t],east_in[t],1'b1);
    assign south_out[t]=pick(south_cfg[t*3+:3],local_out,north_in[t],west_in[t],east_in[t],1'b1);
    assign west_out[t]=pick(west_cfg[t*3+:3],local_out,east_in[t],1'b0,1'b0,1'b0);
    assign east_out[t]=pick(east_cfg[t*3+:3],local_out,west_in[t],1'b0,1'b0,1'b0);
  end endgenerate
endmodule
`default_nettype wire
