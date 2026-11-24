`default_nettype none
// Experimental integration of generic reader/writer tiles with the grid.
// The descriptor selects finite packed words or continuous byte consumption;
// SRAM request/response handling is shared by both paths.
module grid_stream_fabric #(parameter USE_MACRO=0)(
    input wire clk,rst_n,arm,cfg_we,input wire [6:0] cfg_addr,input wire [15:0] cfg_data,
    input wire bank_cfg_we,input wire [1:0] bank_routes,
    input wire host_req,host_we,input wire [9:0] host_addr,input wire [7:0] host_wdata,
    output wire host_ready,host_rvalid,output wire [7:0] host_rdata,
    input wire tx_start,input wire [9:0] tx_base,input wire [10:0] tx_length,
    input wire [9:0] rx_base,input wire [10:0] rx_capacity,
    input wire [1:0] pin_in,output wire [2:0] pin_out,pin_oe,
    output wire configured,output reg tx_done,tx_error,rx_overflow,
    output wire tx_active,output reg [10:0] rx_received,rx_written,
    output wire [2:0] tx_queued,rx_queued,
    input wire spi_start,input wire [9:0] spi_source_addr,spi_dest_addr,
    output reg spi_done,spi_error,output wire spi_active);
  reg [15:0] format,ormask;reg [1:0] format_written;
  reg rx_autostart,descriptor_written,route_valid;
  reg [2:0] route_sel;
  wire format_valid=(&format_written) && descriptor_written && !format[15] &&
    (!format[14] || format[13]) && (format[1:0]==1 || format[1:0]==2) &&
    (format[3:2]==1 || format[3:2]==2);
  always @(posedge clk) begin
    if(!rst_n) begin format<=0;ormask<=0;format_written<=0;rx_autostart<=0;descriptor_written<=0;route_valid<=1;route_sel<=0;end
    else if(!arm && cfg_we) begin
      if(cfg_addr==63) begin format<=cfg_data;format_written[0]<=1;end
      if(cfg_addr==64) begin ormask<=cfg_data;format_written[1]<=1;end
      if(cfg_addr==65) begin rx_autostart<=cfg_data[0];descriptor_written<=cfg_data[15:1]==0;end
      if(cfg_addr==88) begin route_valid<=cfg_data[15:3]==0;route_sel<=cfg_data[2:0];end
    end
    else if(!arm && bank_cfg_we) begin route_valid<=1;route_sel<={bank_routes[1],bank_routes[1],bank_routes[0]};end
  end
  wire grid_configured;
  assign configured=format_valid && grid_configured && route_valid;
  wire [1:0] busy,finished;wire [15:0] rx0,rx1;
  reg [15:0] txword0,txword1,received;
  wire rd_valid,rd_req,rd_active,rd_done,rd_error;wire [10:0] rd_addr;
  wire [7:0] rd_data;wire [1:0] rd_queued,rd_outstanding;
  wire rd_valid_local,reader_consume_local;wire [7:0] rd_data_local;
  wire wr_ready,wr_req,wr_active,wr_done,wr_error;wire [10:0] wr_addr;wire [7:0] wr_data;wire [1:0] wr_queued;
  wire wr_ready_local,writer_valid_local;wire [7:0] writer_input_local;
  wire [2:0] mem_ready,mem_rvalid;wire [23:0] mem_rdata;
  reg armed_seen,cancel,empty_wait;
  reg [10:0] remaining;
  reg [3:0] state;
  reg finished0_seen,finished1_seen,received_seen;
  localparam IDLE=0,READ0=1,READ1=2,READ2=3,READ3=4,FIRE=5,TRANSFER=6,WRITE0=7,WRITE1=8,WAIT_WRITE=9;
  assign spi_active=state!=IDLE;
  assign tx_active=state!=IDLE;
  assign tx_queued={1'b0,rd_queued};assign rx_queued={1'b0,wr_queued};
  wire start=(tx_start || spi_start) && state==IDLE;
  wire [2:0] frame_bytes={1'b0,format[1:0]}+(format[13] ? (format[14] ? 3'd2 : 3'd1) : 3'd0);
  wire [11:0] source_end={1'b0,route_sel[1],tx_base}+{1'b0,tx_length};
  wire [11:0] receive_end={1'b0,route_sel[2],rx_base}+{1'b0,rx_capacity};
  wire start_valid=tx_length!=0 && source_end<=2048 && tx_length>={8'b0,frame_bytes} &&
    (rx_autostart || (rx_capacity!=0 && receive_end<=2048));
  wire reader_start=arm && configured && start && start_valid;
  wire writer_start=arm && configured && ((rx_autostart && !armed_seen) || (!rx_autostart && start && start_valid));
  wire reader_consume=state>=READ0 && state<=READ3 && rd_valid;
  wire fire=state==FIRE;
  grid_core grid(clk,rst_n,arm && format_valid && route_valid,cfg_we && (cfg_addr<63 || (cfg_addr>=69 && cfg_addr<=80)),cfg_addr,cfg_data,
    fire,pin_in,txword0,txword1,rx0,rx1,busy[0],finished[0],busy[1],finished[1],pin_out,pin_oe,grid_configured);
  wire rx_event=rx_autostart && finished[format[4]];
  wire frame_write=!rx_autostart && (state==WRITE0 || state==WRITE1);
  wire writer_valid=rx_autostart ? rx_event : frame_write;
  wire [15:0] decoded_rx=(format[4] ? rx1 : rx0) >> format[12:9];
  wire [7:0] writer_input=rx_autostart ? decoded_rx[7:0] :
    state==WRITE0 && format[3:2]==2 ? received[15:8] : received[7:0];
  // Explicit local stream links between the bank-adjacent FIFOs and the
  // shifter-side scheduler. They are combinational in this prototype.
  grid_stream_link #(.WIDTH(9)) reader_to_shifter({rd_valid_local,rd_data_local},{rd_valid,rd_data});
  grid_stream_link #(.WIDTH(1)) shifter_to_reader(reader_consume,reader_consume_local);
  grid_stream_link #(.WIDTH(9)) shifter_to_writer({writer_valid,writer_input},{writer_valid_local,writer_input_local});
  grid_stream_link #(.WIDTH(1)) writer_to_shifter(wr_ready_local,wr_ready);
  grid_stream_reader #(.DEPTH(2)) reader(clk,rst_n,arm && configured && !cancel,reader_start,{route_sel[1],tx_base},tx_length,
    rd_req,mem_ready[1],rd_addr,mem_rvalid[1],mem_rdata[15:8],rd_valid_local,reader_consume_local,rd_data_local,
    rd_active,rd_done,rd_error,rd_queued,rd_outstanding);
  grid_stream_writer #(.DEPTH(2)) writer(clk,rst_n,arm && configured && !cancel,writer_start,{route_sel[2],rx_base},rx_capacity,
    writer_valid_local,wr_ready_local,writer_input_local,wr_req,mem_ready[2],wr_addr,wr_data,wr_active,wr_done,wr_error,wr_queued);
  wire stream_route_write=bank_cfg_we || (cfg_we && cfg_addr==88);
  wire [2:0] stream_routes=(cfg_we && cfg_addr==88) ? cfg_data[2:0] : {bank_routes[1],bank_routes[1],bank_routes[0]};
  grid_stream_memory #(.USE_MACRO(USE_MACRO)) memory(clk,rst_n,arm,stream_route_write,stream_routes,{wr_addr[10],rd_addr[10]},
    {wr_req,rd_req,host_req},{1'b1,1'b0,host_we},{wr_addr[9:0],rd_addr[9:0],host_addr},{wr_data,8'b0,host_wdata},mem_ready,mem_rvalid,mem_rdata);
  assign host_ready=mem_ready[0];assign host_rvalid=mem_rvalid[0];assign host_rdata=mem_rdata[7:0];
  // Compatibility outputs share the same generic transfer status.
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured) begin
      armed_seen<=0;cancel<=0;empty_wait<=0;state<=IDLE;remaining<=0;txword0<=0;txword1<=0;received<=0;
      tx_done<=0;tx_error<=0;spi_done<=0;spi_error<=0;rx_overflow<=0;rx_received<=0;rx_written<=0;
      finished0_seen<=0;finished1_seen<=0;received_seen<=0;
    end else begin
      tx_done<=0;spi_done<=0;cancel<=0;
      if(!armed_seen) begin
        armed_seen<=1;
        if(rx_autostart && (rx_capacity==0 || receive_end>2048)) rx_overflow<=1;
      end
      if(rx_event) begin
        if(wr_ready) rx_received<=rx_received+1'b1;else rx_overflow<=1;
      end
      if(rx_autostart && wr_req && mem_ready[2]) rx_written<=rx_written+1'b1;
      case(state)
        IDLE: if(start) begin
          tx_error<=0;spi_error<=0;empty_wait<=0;finished0_seen<=0;finished1_seen<=0;received_seen<=0;
          if(!start_valid) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;end
          else begin remaining<=tx_length;state<=READ0;end
        end
        READ0: if(rd_valid) begin
          remaining<=remaining-1'b1;
          if(format[1:0]==1) begin txword0<=({8'b0,rd_data} << format[8:5]) | ormask;state<=format[13] ? READ2 : FIRE;end
          else begin txword0[15:8]<=rd_data;state<=READ1;end
        end else if(rd_done) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
        READ1: if(rd_valid) begin remaining<=remaining-1'b1;txword0<=({txword0[15:8],rd_data} << format[8:5]) | ormask;state<=format[13] ? READ2 : FIRE;end
          else if(rd_done) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
        READ2: if(rd_valid) begin
          remaining<=remaining-1'b1;
          if(format[14]) begin txword1[15:8]<=rd_data;state<=READ3;end
          else begin txword1<={8'b0,rd_data};state<=FIRE;end
        end else if(rd_done) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
        READ3: if(rd_valid) begin remaining<=remaining-1'b1;txword1[7:0]<=rd_data;state<=FIRE;end
          else if(rd_done) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
        FIRE: state<=TRANSFER;
        TRANSFER: begin
          if(finished[0]) finished0_seen<=1;
          if(finished[1]) finished1_seen<=1;
          if(!rx_autostart && finished[format[4]]) begin received<=decoded_rx;received_seen<=1;end
          if((finished0_seen || finished[0]) && (!format[13] || finished1_seen || finished[1]) &&
             (rx_autostart || received_seen || finished[format[4]])) begin
            finished0_seen<=0;finished1_seen<=0;received_seen<=0;
            if(!rx_autostart) state<=WRITE0;
            else if(remaining!=0) state<=READ0;
            else begin state<=IDLE;tx_done<=1;spi_done<=1;end
          end
        end
        WRITE0: if(wr_ready) state<=format[3:2]==2 ? WRITE1 : (remaining!=0 ? READ0 : WAIT_WRITE);
          else if(wr_done || !wr_active) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
        WRITE1: if(wr_ready) state<=remaining!=0 ? READ0 : WAIT_WRITE;
          else if(wr_done || !wr_active) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
        WAIT_WRITE: if(wr_done) begin state<=IDLE;tx_done<=1;spi_done<=1;end
          else if(!wr_req && wr_queued==0) begin
            if(empty_wait) begin tx_error<=1;spi_error<=1;tx_done<=1;spi_done<=1;cancel<=1;state<=IDLE;end
            else empty_wait<=1;
          end else empty_wait<=0;
        default:state<=IDLE;
      endcase
    end
  end
  wire unused=&{1'b0,spi_source_addr,spi_dest_addr,rd_active,rd_error,rd_outstanding,wr_active,wr_error};
endmodule
`default_nettype wire
