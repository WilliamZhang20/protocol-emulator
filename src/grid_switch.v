`default_nettype none
// Tracks 0/1 route horizontal then vertical; tracks 2/3 route vertical then
// horizontal. Tracks never change class or direction, so arbitrary selector
// settings cannot create a combinational cycle within the routing network.
module grid_switch(
  input wire [3:0] north_in, south_in, west_in, east_in,
  input wire [3:0] local_out,
  input wire [11:0] north_cfg, south_cfg, west_cfg, east_cfg,
  output wire [3:0] north_out, south_out, west_out, east_out);
  genvar t;
  generate for(t=0;t<4;t=t+1) begin: tracks
    function automatic pick;
      input [2:0] s; input [3:0] local_bits;
      input straight, turn_a, turn_b; input allow_turn;
      begin
        case(s)
          1:pick=local_bits[0]; 2:pick=local_bits[1];
          3:pick=local_bits[2]; 4:pick=local_bits[3];
          5:pick=straight; 6:pick=allow_turn && turn_a;
          7:pick=allow_turn && turn_b; default:pick=1'b0;
        endcase
      end
    endfunction
    assign north_out[t]=pick(north_cfg[t*3+:3],local_out,south_in[t],west_in[t],east_in[t],t<2);
    assign south_out[t]=pick(south_cfg[t*3+:3],local_out,north_in[t],west_in[t],east_in[t],t<2);
    assign west_out[t]=pick(west_cfg[t*3+:3],local_out,east_in[t],north_in[t],south_in[t],t>=2);
    assign east_out[t]=pick(east_cfg[t*3+:3],local_out,west_in[t],north_in[t],south_in[t],t>=2);
  end endgenerate
endmodule
`default_nettype wire
