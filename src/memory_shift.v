`default_nettype none
// Experimental transaction adapter, not compiled protocol control. It fetches
// two big-endian bytes, sends 9..16 low-order bits MSB first, and writes the
// received right-aligned word as two bytes. Addresses must be <= 1022.
module memory_shift(input wire clk, input wire rst_n, input wire start,
    input wire [4:0] width, input wire [7:0] half_period,
    input wire [9:0] source_addr, input wire [9:0] dest_addr,
    output reg req, output reg we, output reg [9:0] addr,
    output reg [7:0] wdata, input wire ready, input wire rvalid,
    input wire [7:0] rdata, input wire serial_in,
    output wire sck, output wire serial_out, output reg done, output reg error,
    output wire active);
  localparam IDLE=0, READ0=1, WAIT0=2, READ1=3, WAIT1=4,
             START=5, TRANSFER=6, WRITE0=7, WRITE1=8;
  reg [3:0] state;
  reg [7:0] first;
  reg [15:0] transmit;
  reg [4:0] width_latched;
  reg [7:0] period_latched;
  reg [9:0] src_latched, dst_latched;
  wire timer_rise, timer_fall, busy, shift_done;
  wire [15:0] receive;
  assign active = state != IDLE;
  proto_timer timer(clk, rst_n, busy, period_latched, sck, timer_rise, timer_fall);
  proto_shift shift(clk, rst_n, state == START, timer_rise, timer_fall,
                    serial_in, transmit, width_latched, serial_out, busy, shift_done, receive);
  always @* begin
    req=0; we=0; addr=0; wdata=0;
    case (state)
      READ0: begin req=1; addr=src_latched; end
      READ1: begin req=1; addr=src_latched+10'd1; end
      WRITE0: begin req=1; we=1; addr=dst_latched; wdata=receive[15:8]; end
      WRITE1: begin req=1; we=1; addr=dst_latched+10'd1; wdata=receive[7:0]; end
      default: begin end
    endcase
  end
  always @(posedge clk) begin
    if (!rst_n) begin
      state<=IDLE; done<=0; error<=0; first<=0; transmit<=0;
      width_latched<=0; period_latched<=0; src_latched<=0; dst_latched<=0;
    end else begin
      done<=0;
      case (state)
        IDLE: if (start) begin
          error<=0;
          if (width<9 || width>16 || half_period<2 || source_addr==1023 || dest_addr==1023) begin
            error<=1; done<=1;
          end else begin
            width_latched<=width; period_latched<=half_period;
            src_latched<=source_addr; dst_latched<=dest_addr; state<=READ0;
          end
        end
        READ0: if (ready) state<=WAIT0;
        WAIT0: if (rvalid) begin first<=rdata; state<=READ1; end
        READ1: if (ready) state<=WAIT1;
        WAIT1: if (rvalid) begin transmit<={first,rdata} << (16-width_latched); state<=START; end
        START: state<=TRANSFER;
        TRANSFER: if (shift_done) state<=WRITE0;
        WRITE0: if (ready) state<=WRITE1;
        WRITE1: if (ready) begin done<=1; state<=IDLE; end
        default: state<=IDLE;
      endcase
    end
  end
endmodule

// Host is requester 0 and the transfer adapter requester 1. Routing is a
// configuration input so either requester can be assigned to either bank.
module memory_shift_fabric #(parameter USE_MACRO=0)(
    input wire clk, input wire rst_n, input wire arm,
    input wire cfg_we, input wire [1:0] cfg_routes,
    input wire host_req, input wire host_we, input wire [9:0] host_addr,
    input wire [7:0] host_wdata, output wire host_ready,
    output wire host_rvalid, output wire [7:0] host_rdata,
    input wire start, input wire [4:0] width, input wire [7:0] half_period,
    input wire [9:0] source_addr, input wire [9:0] dest_addr,
    input wire serial_in, output wire sck, output wire serial_out,
    output wire done, output wire error, output wire transfer_waiting,
    output wire transfer_active);
  wire actor_req, actor_we, actor_ready, actor_valid;
  wire [9:0] actor_addr;
  wire [7:0] actor_wdata, actor_rdata;
  wire [1:0] ready, valid;
  wire [15:0] data;
  assign host_ready=ready[0]; assign actor_ready=ready[1];
  assign host_rvalid=valid[0]; assign actor_valid=valid[1];
  assign host_rdata=data[7:0]; assign actor_rdata=data[15:8];
  assign transfer_waiting=actor_req && !actor_ready;
  experiment_memory_fabric #(.USE_MACRO(USE_MACRO)) memory(
      clk,rst_n,arm,cfg_we,cfg_routes,{actor_req,host_req},{actor_we,host_we},
      {actor_addr,host_addr},{actor_wdata,host_wdata},ready,valid,data);
  // Disarming cancels the adapter at the next edge; accepted writes are not
  // rolled back. Gate start so an idle disarmed fabric cannot begin work.
  memory_shift actor(clk,rst_n && arm,start && arm,width,half_period,source_addr,dest_addr,
      actor_req,actor_we,actor_addr,actor_wdata,actor_ready,actor_valid,actor_rdata,
      serial_in,sck,serial_out,done,error,transfer_active);
endmodule
`default_nettype wire
