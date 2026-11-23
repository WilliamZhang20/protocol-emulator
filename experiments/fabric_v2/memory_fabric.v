`default_nettype none
// Experimental stream adapter. A configured byte packing rule connects the
// two-bank memory fabric to the v2 tiles; there is no instruction memory.
// This adapter currently handles one finite source and destination object.
module fabric_v2_memory #(parameter USE_MACRO=0)(
    input wire clk,rst_n,arm,cfg_we,
    input wire [4:0] cfg_addr,input wire [15:0] cfg_data,
    input wire bank_cfg_we,input wire [1:0] bank_routes,
    input wire host_req,host_we,input wire [9:0] host_addr,input wire [7:0] host_wdata,
    output wire host_ready,host_rvalid,output wire [7:0] host_rdata,
    input wire start,input wire [9:0] source_addr,dest_addr,
    input wire [1:0] pin_in,output wire [2:0] pin_out,pin_oe,
    output wire [1:0] shift_busy,shift_done,
    output wire configured,output reg done,error,output wire active);
  reg [15:0] format, ormask;
  reg [1:0] fmt_written;
  wire adapter_valid=fmt_written==2'b11 && format[15:13]==0 &&
       (format[1:0]==1 || format[1:0]==2) && (format[3:2]==1 || format[3:2]==2);
  wire tile_configured;
  wire tiles_arm=arm && adapter_valid;
  assign configured=adapter_valid && tile_configured;
  always @(posedge clk) begin
    if (!rst_n) begin format<=0;ormask<=0;fmt_written<=0;end
    else if (!arm && cfg_we) begin
      if(cfg_addr==22) begin format<=cfg_data;fmt_written[0]<=1;end
      if(cfg_addr==23) begin ormask<=cfg_data;fmt_written[1]<=1;end
    end
  end
  reg fire;
  reg [15:0] txword;
  wire [15:0] rx0,rx1;
  fabric_v2 fabric(clk,rst_n,tiles_arm,cfg_we,cfg_addr,cfg_data,{1'b0,fire},pin_in,txword,16'd0,
      pin_out,pin_oe,rx0,rx1,shift_busy,shift_done,tile_configured);
  reg actor_req,actor_we;
  reg [9:0] actor_addr;
  reg [7:0] actor_wdata;
  wire [1:0] ready,rvalid;
  wire [15:0] data;
  assign host_ready=ready[0];assign host_rvalid=rvalid[0];assign host_rdata=data[7:0];
  experiment_memory_fabric #(.USE_MACRO(USE_MACRO)) memory(
      clk,rst_n,arm,bank_cfg_we,bank_routes,{actor_req,host_req},{actor_we,host_we},
      {actor_addr,host_addr},{actor_wdata,host_wdata},ready,rvalid,data);
  localparam IDLE=0,READ0=1,WAIT0=2,READ1=3,WAIT1=4,FIRE=5,TRANSFER=6,WRITE0=7,WRITE1=8;
  reg [3:0] state;
  reg [9:0] src,dst;
  reg [7:0] first_byte;
  reg [15:0] received;
  reg tx_finished,rx_finished;
  assign active=state!=IDLE;
  always @* begin
    actor_req=0;actor_we=0;actor_addr=0;actor_wdata=0;fire=0;
    case(state)
      READ0: begin actor_req=1;actor_addr=src;end
      READ1: begin actor_req=1;actor_addr=src+10'd1;end
      FIRE: fire=1;
      WRITE0: begin actor_req=1;actor_we=1;actor_addr=dst;
        actor_wdata=format[3:2]==2 ? received[15:8] : received[7:0];end
      WRITE1: begin actor_req=1;actor_we=1;actor_addr=dst+10'd1;actor_wdata=received[7:0];end
      default: begin end
    endcase
  end
  always @(posedge clk) begin
    if (!rst_n || !arm || !configured) begin
      state<=IDLE;src<=0;dst<=0;first_byte<=0;txword<=0;received<=0;done<=0;error<=0;
      tx_finished<=0;rx_finished<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(start) begin
          error<=0;tx_finished<=0;rx_finished<=0;
          if ((format[1:0]==2 && source_addr==1023) || (format[3:2]==2 && dest_addr==1023)) begin
            error<=1;done<=1;
          end else begin src<=source_addr;dst<=dest_addr;state<=READ0;end
        end
        READ0: if(ready[1]) state<=WAIT0;
        WAIT0: if(rvalid[1]) begin
          first_byte<=data[15:8];
          if(format[1:0]==1) begin txword<=({8'd0,data[15:8]} << format[8:5]) | ormask;state<=FIRE;end
          else state<=READ1;
        end
        READ1: if(ready[1]) state<=WAIT1;
        WAIT1: if(rvalid[1]) begin txword<=({first_byte,data[15:8]} << format[8:5]) | ormask;state<=FIRE;end
        FIRE: state<=TRANSFER;
        TRANSFER: begin
          if(shift_done[0]) tx_finished<=1;
          if(shift_done[format[4]]) begin
            received<=(format[4] ? rx1 : rx0) >> format[12:9];rx_finished<=1;
          end
          if((tx_finished || shift_done[0]) && (rx_finished || shift_done[format[4]])) state<=WRITE0;
        end
        WRITE0: if(ready[1]) begin if(format[3:2]==1) begin state<=IDLE;done<=1;end else state<=WRITE1;end
        WRITE1: if(ready[1]) begin state<=IDLE;done<=1;end
        default:state<=IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
