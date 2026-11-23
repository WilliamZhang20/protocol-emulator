`default_nettype none
// Experimental integration: the same eight configurable registered routes
// and control table as spi_fabric, connected to two single-port SRAM banks.
// A narrow memory adapter handles byte requests; it is not protocol control.
module memory_spi_fabric #(parameter USE_MACRO=0)(
    input wire clk, input wire rst_n, input wire arm,
    input wire cfg_we, input wire [4:0] cfg_addr, input wire [15:0] cfg_data,
    input wire bank_cfg_we, input wire [1:0] bank_routes,
    input wire trigger, input wire [9:0] source_addr, input wire [9:0] dest_addr,
    input wire host_req, input wire host_we, input wire [9:0] host_addr,
    input wire [7:0] host_wdata, output wire host_ready,
    output wire host_rvalid, output wire [7:0] host_rdata,
    input wire miso, output wire cs, output wire sck, output wire mosi,
    output wire [2:0] oe, output reg done, output reg error, output wire active);
  reg [7:0] half_period;
  reg [4:0] width;
  reg [15:0] routes;
  reg [17:0] written;
  wire cfg_control = rst_n && !arm && cfg_we && cfg_addr>=2 && cfg_addr<=17;
  wire [3:0] cfg_row = cfg_addr[3:0]-4'd2;
  always @(posedge clk) begin
    if (!rst_n) begin half_period<=0; width<=0; routes<=0; written<=0; end
    else if (!arm && cfg_we) begin
      if (cfg_addr==0) begin half_period<=cfg_data[7:0]; width<=cfg_data[12:8]; written[0]<=1; end
      else if (cfg_addr==1) begin routes<=cfg_data; written[1]<=1; end
      else if (cfg_addr<=17) written[cfg_addr]<=1;
    end
  end
  wire valid = &written && width>=9 && width<=16 && half_period>=8;
  wire live = rst_n && arm && valid;
  reg cs_route_ready;
  always @(posedge clk)
    if (!live) cs_route_ready <= 0; else cs_route_ready <= 1;
  wire selected, shift_start, control_done, shift_busy, shift_done;
  wire timer_level, timer_rise, timer_fall, serial_out, serial_in, routed_serial;
  wire routed_start, routed_run, routed_rise, routed_fall, routed_in, routed_cs, routed_sck;
  reg fire;
  reg [15:0] transmit;
  wire [15:0] receive;
  proto_control control(clk,rst_n,live,cfg_control,cfg_row,cfg_data[4:0],
                        fire,shift_done,selected,shift_start,control_done);
  proto_timer timer(clk,live,routed_run,half_period,timer_level,timer_rise,timer_fall);
  proto_shift shift(clk,live,routed_start,routed_rise,routed_fall,routed_in,
                    transmit,width,serial_out,shift_busy,shift_done,receive);
  proto_pin_in input_pin(clk,rst_n,miso,serial_in);
  proto_route r0(clk,live,routes[1:0],{timer_rise,fire,1'b0,shift_start},routed_start);
  proto_route r1(clk,live,routes[3:2],{1'b1,1'b0,selected,shift_busy},routed_run);
  proto_route r2(clk,live,routes[5:4],{fire,1'b0,timer_fall,timer_rise},routed_rise);
  proto_route r3(clk,live,routes[7:6],{fire,1'b0,timer_rise,timer_fall},routed_fall);
  proto_route r4(clk,live,routes[9:8],{serial_out,1'b1,1'b0,serial_in},routed_in);
  proto_route r5(clk,live,routes[11:10],{1'b1,1'b0,timer_level,serial_out},routed_serial);
  proto_route r6(clk,live,routes[13:12],{1'b1,1'b0,serial_out,timer_level},routed_sck);
  // Option 2 permits a source program to bind CS directly to !shift.busy.
  proto_route r7(clk,live,routes[15:14],{1'b1,!shift_busy,selected,!selected},routed_cs);
  // The registered route resets low. Delay CS enable by one edge so the
  // configured idle-high source has propagated before it can drive a pin.
  proto_pin_out cs_pin(clk,rst_n,live && cs_route_ready,routed_cs,cs,oe[0]);
  proto_pin_out sck_pin(clk,rst_n,live,routed_sck,sck,oe[1]);
  proto_pin_out mosi_pin(clk,rst_n,live,routed_serial,mosi,oe[2]);

  localparam IDLE=0,READ0=1,WAIT0=2,READ1=3,WAIT1=4,FIRE=5,
             TRANSFER=6,WRITE0=7,WRITE1=8;
  reg [3:0] state;
  reg [7:0] first;
  reg [9:0] src_addr,dst_addr;
  reg req,we;
  reg [9:0] addr;
  reg [7:0] wdata;
  wire [1:0] ready,rvalid;
  wire [15:0] rdata;
  assign active = state!=IDLE;
  assign host_ready=ready[0];
  assign host_rvalid=rvalid[0];
  assign host_rdata=rdata[7:0];
  experiment_memory_fabric #(.USE_MACRO(USE_MACRO)) memory(
      clk,rst_n,arm,bank_cfg_we,bank_routes,{req,host_req},{we,host_we},
      {addr,host_addr},{wdata,host_wdata},ready,rvalid,rdata);
  always @* begin
    req=0; we=0; addr=0; wdata=0; fire=0;
    case(state)
      READ0: begin req=1; addr=src_addr; end
      READ1: begin req=1; addr=src_addr+10'd1; end
      FIRE: fire=1;
      WRITE0: begin req=1; we=1; addr=dst_addr; wdata=receive[15:8]; end
      WRITE1: begin req=1; we=1; addr=dst_addr+10'd1; wdata=receive[7:0]; end
      default: begin end
    endcase
  end
  always @(posedge clk) begin
    if (!live) begin state<=IDLE; first<=0; transmit<=0; src_addr<=0; dst_addr<=0; done<=0; error<=0; end
    else begin
      done<=0;
      case(state)
        IDLE: if (trigger) begin
          error<=0;
          if (source_addr==1023 || dest_addr==1023) begin error<=1; done<=1; end
          else begin src_addr<=source_addr; dst_addr<=dest_addr; state<=READ0; end
        end
        READ0: if (ready[1]) state<=WAIT0;
        WAIT0: if (rvalid[1]) begin first<=rdata[15:8]; state<=READ1; end
        READ1: if (ready[1]) state<=WAIT1;
        WAIT1: if (rvalid[1]) begin transmit<={first,rdata[15:8]} << (16-width); state<=FIRE; end
        FIRE: state<=TRANSFER;
        TRANSFER: if (shift_done) state<=WRITE0;
        WRITE0: if (ready[1]) state<=WRITE1;
        WRITE1: if (ready[1]) begin done<=1; state<=IDLE; end
        default: state<=IDLE;
      endcase
    end
  end
  wire unused_control_done = control_done;
endmodule
`default_nettype wire
