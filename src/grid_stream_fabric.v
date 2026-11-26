`default_nettype none
// Experimental integration of generic reader/writer tiles with the grid.
// The descriptor selects finite packed words or continuous byte consumption;
// SRAM request/response handling is shared by both paths.
module grid_stream_fabric #(parameter USE_MACRO=0)(
    input wire clk,rst_n,arm_in,cfg_we,input wire [7:0] cfg_addr,input wire [15:0] cfg_data,
    input wire bank_cfg_we,input wire [1:0] bank_routes,
    input wire host_req,host_we,input wire [9:0] host_addr,input wire [7:0] host_wdata,
    output wire host_ready,host_rvalid,output wire [7:0] host_rdata,
    input wire tx_start,input wire [9:0] tx_base,input wire [10:0] tx_length,
    input wire [9:0] rx_base,input wire [10:0] rx_capacity,
    input wire [1:0] pin_in,output wire [2:0] pin_out,pin_oe,
    output wire configured,output wire tx_done,tx_error,output reg rx_overflow,
    output wire tx_active,output reg [10:0] rx_received,rx_written,
    output wire [2:0] tx_queued,rx_queued,
    input wire spi_start,input wire [9:0] spi_source_addr,spi_dest_addr,
    output wire spi_done,spi_error,spi_active,
    // Configuration page: 0 the grid and fabric words, 1 lane cores (64 words
    // per lane at 256 + 64k; lane 0 only for now).
    input wire cfg_page);
  // Configuration and bank-route writes are accepted only while the host has
  // the fabric disarmed, then travel the registered grid_config_tree to the
  // cell that owns them. The fabric arms only after every accepted write has
  // landed; disarm is immediate. A start that arrives in that window is held.
  wire [16*26-1:0] cfg_leaves;
  wire cfg_busy;
  wire [25:0] lane_leaf;
  grid_config_tree config_tree(clk,rst_n,!arm_in && (cfg_we || bank_cfg_we),!cfg_we,cfg_we && cfg_page,
    cfg_we ? cfg_addr : 8'd0,cfg_we ? cfg_data : {14'b0,bank_routes},cfg_leaves,lane_leaf,cfg_busy);
  // Lane 0's words: page-1 addresses 0-63 (256-319 on the host link).
  wire core_cfg_we=lane_leaf[25] && !lane_leaf[24] && lane_leaf[23:22]==2'd0;
  wire arm=arm_in && !cfg_busy;
  wire leaf_valid=cfg_leaves[15*26+25],leaf_bank=cfg_leaves[15*26+24];
  wire [7:0] leaf_addr=cfg_leaves[15*26+16+:8];
  wire [15:0] leaf_data=cfg_leaves[15*26+:16];
  wire leaf_we=leaf_valid && !leaf_bank;
  wire seq_valid=cfg_leaves[6*26+25] && !cfg_leaves[6*26+24];
  wire [7:0] seq_addr=cfg_leaves[6*26+16+:8];
  wire [15:0] seq_data=cfg_leaves[6*26+:16];
  reg start_held;
  wire start_request=tx_start || spi_start || start_held;
  always @(posedge clk) begin
    if(!rst_n || !arm_in) start_held<=0;
    else start_held<=!arm && start_request;
  end
  reg [15:0] format,ormask;reg [1:0] format_written;
  reg rx_autostart,descriptor_written,route_valid;
  reg [2:0] route_sel;
  reg frame_tx_done,frame_tx_error,frame_spi_done,frame_spi_error;
  wire frame_tx_active,frame_spi_active;
  reg temporal_mode,temporal_mode_valid,temporal_settings_valid,temporal_settings_written;
  // Word 91 bit 2: the lane controller drives the lane instead of the row
  // sequencer and frame engine (bits 0 and 2 together are invalid).
  reg lane_mode;
  reg packet_mode,packet_mode_valid,packet_running,packet_done,packet_error;
  reg [10:0] packet_left;
  reg packet_started;
  wire packet_request,packet_stop,packet_configured,packet_grant,packet_tick;
  reg [3:0] temporal_entry,temporal_idle;
  wire format_valid=(&format_written) && descriptor_written && !format[15] &&
    (!format[14] || format[13]) && (format[1:0]==1 || format[1:0]==2) &&
    (format[3:2]==1 || format[3:2]==2);
  always @(posedge clk) begin
    if(!rst_n) begin format<=0;ormask<=0;format_written<=0;rx_autostart<=0;descriptor_written<=0;route_valid<=1;route_sel<=0;
      packet_mode<=0;packet_mode_valid<=1;temporal_mode<=0;lane_mode<=0;temporal_mode_valid<=1;temporal_settings_valid<=0;temporal_settings_written<=0;temporal_entry<=0;temporal_idle<=0;end
    else if(leaf_we) begin
      if(leaf_addr==63) begin format<=leaf_data;format_written[0]<=1;end
      if(leaf_addr==64) begin ormask<=leaf_data;format_written[1]<=1;end
      if(leaf_addr==65) begin rx_autostart<=leaf_data[0];descriptor_written<=leaf_data[15:1]==0;end
      if(leaf_addr==88) begin route_valid<=leaf_data[15:3]==0;route_sel<=leaf_data[2:0];end
      if(leaf_addr==91) begin temporal_mode<=leaf_data[0];lane_mode<=leaf_data[2];
        temporal_mode_valid<=leaf_data[15:3]==0 && !(leaf_data[0] && leaf_data[2]);end
      if(leaf_addr==93) begin packet_mode<=leaf_data[0];packet_mode_valid<=leaf_data[15:1]==0;end
      if(leaf_addr==92) begin temporal_entry<=leaf_data[3:0];temporal_idle<=leaf_data[7:4];
        temporal_settings_valid<=leaf_data[15:8]==0;temporal_settings_written<=1;end
    end
    else if(leaf_valid) begin route_valid<=1;route_sel<={leaf_data[1],leaf_data[1],leaf_data[0]};end
  end
  wire grid_configured,contexts_configured,temporal_tick;
  wire [1:0] temporal_pins;
  wire [15:0] temporal_programmed;
  wire temporal_active,temporal_done,temporal_error,temporal_halting;
  wire [3:0] temporal_state,sequencer_actions;
  wire [1:0] seq_events,seq_event_enable;
  wire [3:0] lane_actions;
  wire [3:0] temporal_actions=lane_mode ? lane_actions : temporal_active ? sequencer_actions : temporal_idle;
  wire control_mode=temporal_mode || lane_mode;
  // Word 94: {paging enable, 5'b0, page base[9:0]}. Pages live in the host
  // bank (word 88 bit 0) at base + 64*page: 16 rows, then 5 context words.
  reg [15:0] page_cfg;
  always @(posedge clk) begin
    if(!rst_n) page_cfg<=0;
    else if(seq_valid && seq_addr==94) page_cfg<=seq_data;
  end
  wire paging=page_cfg[15];
  wire seq_loading,page_row_we,page_ctx_we,page_done,page_owns_port,page_resp_pending,page_req;
  wire [3:0] seq_load_page,page_row_addr;wire [15:0] page_row_data;wire [79:0] page_ctx_data;wire [9:0] page_addr;
  // Lane mode needs only the lane core's own validity (its words, page 1);
  // the row sequencer needs its settings, contexts and entry program.
  wire core_configured;
  wire temporal_ready=!control_mode || (temporal_mode_valid && !rx_autostart && (lane_mode ? core_configured :
    (temporal_settings_valid && temporal_settings_written && contexts_configured && (paging || temporal_programmed[temporal_entry]))));
  wire packet_ready=!packet_mode || (packet_mode_valid && !rx_autostart && packet_configured);
  wire configured_now=format_valid && grid_configured && route_valid && temporal_ready && packet_ready && page_cfg[14:10]==0;
  reg configured_q;
  // Validity is evaluated while disarmed; armed configuration changes only by
  // the lane core's live writes, which the core checks before accepting, so
  // it is held while armed.
  always @(posedge clk) if(!rst_n) configured_q<=0; else if(!arm) configured_q<=configured_now;
  assign configured=configured_q;
  // Lane A is the frame, packet or temporal engine. Lane B (grid_core cell
  // 13) runs beside it from the same start. The host sees one transfer: done
  // waits until both lanes have finished, and either lane's error is reported.
  wire lane_ctl_active,lane_ctl_done,lane_ctl_error;
  // A lane run is finished once the bytes it pushed are in SRAM; then both
  // streams close, so the next run starts them at their bases.
  reg lane_draining,lane_drain_error,lane_close;
  wire wr_req,wr_active;wire [1:0] wr_queued;
  wire lane_drained=!wr_req && wr_queued==0;
  wire lane_finished=lane_draining && lane_drained;
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured) begin lane_draining<=0;lane_drain_error<=0;lane_close<=0;end
    else begin
      lane_close<=lane_finished;
      if(lane_ctl_done) begin lane_draining<=1;lane_drain_error<=lane_ctl_error;end
      else if(lane_finished) lane_draining<=0;
    end
  end
  wire lane_a_done=lane_mode ? lane_finished : temporal_mode ? temporal_done : packet_mode ? packet_done : frame_tx_done;
  wire lane_a_error=lane_mode ? lane_drain_error : temporal_mode ? temporal_error : packet_mode ? packet_error : frame_tx_error;
  wire lane_a_running=lane_mode ? (lane_ctl_active || lane_draining) : temporal_mode ? temporal_active : packet_mode ? packet_running : frame_tx_active;
  wire lane_b_active,lane_b_done,lane_b_error,host_start;
  reg lane_a_held,lane_a_held_error,lane_b_failed,finished_error;
  wire finish_now=(lane_a_done && !lane_b_active) || (lane_a_held && lane_b_done);
  wire finish_error=lane_a_error || lane_a_held_error || lane_b_failed || (lane_b_done && lane_b_error);
  always @(posedge clk) begin
    if(!rst_n || !arm) begin lane_a_held<=0;lane_a_held_error<=0;lane_b_failed<=0;finished_error<=0;end
    else if(host_start) begin lane_a_held<=0;lane_a_held_error<=0;lane_b_failed<=0;finished_error<=0;end
    else begin
      if(lane_a_done && lane_b_active) begin lane_a_held<=1;lane_a_held_error<=lane_a_error;end
      if(finish_now) begin lane_a_held<=0;lane_b_failed<=0;finished_error<=finish_error;end
      else if(lane_b_done && lane_b_error) lane_b_failed<=1;
    end
  end
  assign tx_done=finish_now;assign spi_done=finish_now;
  // Error is a level from finish until the next start, as each engine's was.
  assign tx_error=finish_now ? finish_error : finished_error;assign spi_error=tx_error;
  assign tx_active=start_held || lane_a_running || lane_b_active || lane_a_held;
  assign spi_active=tx_active;
  wire [1:0] busy,finished;wire [15:0] rx0,rx1;
  reg [15:0] txword0,txword1,received;
  wire rd_valid,rd_req,rd_active,rd_done,rd_error;wire [10:0] rd_addr;
  wire [7:0] rd_data;wire [1:0] rd_queued,rd_outstanding;
  wire rd_valid_local,reader_consume_local;wire [7:0] rd_data_local;
  wire wr_ready,wr_done,wr_error;wire [10:0] wr_addr;wire [7:0] wr_data;
  wire wr_ready_local,writer_valid_local;wire [7:0] writer_input_local;
  wire [2:0] mem_ready,mem_rvalid;wire [23:0] mem_rdata;
  reg armed_seen,cancel,empty_wait;
  reg [10:0] remaining;
  reg [10:0] temporal_tx_cursor,temporal_rx_cursor,temporal_tx_left,temporal_rx_left;
  reg temporal_request_prev;
  reg [3:0] state;
  reg finished0_seen,finished1_seen,received_seen;
  localparam IDLE=0,READ0=1,READ1=2,READ2=3,READ3=4,FIRE=5,TRANSFER=6,WRITE0=7,WRITE1=8,WAIT_WRITE=9;
  assign frame_spi_active=state!=IDLE;
  assign frame_tx_active=state!=IDLE;
  assign tx_queued={1'b0,rd_queued};assign rx_queued={1'b0,wr_queued};
  assign host_start=arm && start_request && state==IDLE;
  wire temporal_request=!packet_mode && temporal_active && sequencer_actions[3] && sequencer_actions[2] && !temporal_request_prev && !temporal_halting;
  wire start=!packet_mode && !lane_mode && (temporal_mode ? temporal_request : host_start) && state==IDLE;
  wire [2:0] frame_bytes={1'b0,format[1:0]}+(format[13] ? (format[14] ? 3'd2 : 3'd1) : 3'd0);
  wire [10:0] selected_tx_base=temporal_mode && !packet_mode ? temporal_tx_cursor : {route_sel[1],tx_base};
  wire [10:0] selected_rx_base=temporal_mode && !packet_mode ? temporal_rx_cursor : {route_sel[2],rx_base};
  wire [10:0] selected_tx_length=temporal_mode && !packet_mode ? {8'b0,frame_bytes} : tx_length;
  wire [10:0] selected_rx_capacity=temporal_mode && !packet_mode ? {9'b0,format[3:2]} : rx_capacity;
  wire [11:0] source_end={1'b0,selected_tx_base}+{1'b0,selected_tx_length};
  wire [11:0] receive_end={1'b0,selected_rx_base}+{1'b0,selected_rx_capacity};
  wire temporal_capacity_ok=!temporal_mode || (temporal_tx_left>=selected_tx_length && temporal_rx_left>=selected_rx_capacity);
  wire start_valid=selected_tx_length!=0 && source_end<=2048 && selected_tx_length>={8'b0,frame_bytes} &&
    temporal_capacity_ok && (rx_autostart || (selected_rx_capacity!=0 && receive_end<=2048));
  always @(posedge clk) begin
    if(!rst_n || !arm || !temporal_mode) begin
      temporal_tx_cursor<=0;temporal_rx_cursor<=0;temporal_tx_left<=0;temporal_rx_left<=0;temporal_request_prev<=0;
    end else begin
      temporal_request_prev<=sequencer_actions[2] && sequencer_actions[3];
      if(host_start && !temporal_active) begin
        temporal_tx_cursor<={route_sel[1],tx_base};temporal_rx_cursor<={route_sel[2],rx_base};
        temporal_tx_left<=tx_length;temporal_rx_left<=rx_capacity;
      end else if(start && start_valid) begin
        temporal_tx_cursor<=temporal_tx_cursor+selected_tx_length;
        temporal_rx_cursor<=temporal_rx_cursor+selected_rx_capacity;
        temporal_tx_left<=temporal_tx_left-selected_tx_length;
        temporal_rx_left<=temporal_rx_left-selected_rx_capacity;
      end
    end
  end
  wire packet_start=packet_mode && host_start && !packet_running;
  wire packet_start_valid=tx_length!=0 && ({1'b0,route_sel[1],tx_base}+{1'b0,tx_length}<=2048);
  assign packet_grant=packet_running && packet_request && rd_valid && (packet_started || packet_tick);
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured || !packet_mode) begin
      packet_running<=0;packet_done<=0;packet_error<=0;packet_left<=0;packet_started<=0;
    end else begin
      packet_done<=0;
      if(packet_start) begin
        packet_error<=!packet_start_valid;packet_left<=tx_length;packet_started<=0;
        packet_running<=packet_start_valid;
        if(!packet_start_valid) packet_done<=1;
      end else if(packet_running) begin
        if(packet_grant) begin packet_left<=packet_left-1'b1;packet_started<=1;end
        if((rd_done && rd_error) || (packet_started && packet_request && !rd_valid && packet_left!=0)) begin
          packet_running<=0;packet_done<=1;packet_error<=1;
        end else if(packet_stop) begin packet_running<=0;packet_done<=1;packet_error<=packet_left!=0;end
      end
    end
  end
  // Lane mode: the host start opens the reader and writer on the host's
  // bases and lengths; the lane controller pulls and pushes bytes.
  wire lane_reader_go=host_start && tx_length!=0 && source_end<=2048;
  wire lane_writer_go=host_start && rx_capacity!=0 && receive_end<=2048;
  wire lane_rd_consume;
  wire reader_start=arm && configured && (lane_mode ? lane_reader_go : packet_mode ? packet_start && packet_start_valid : start && start_valid);
  wire writer_start=arm && configured && !packet_mode && (lane_mode ? lane_writer_go :
    ((rx_autostart && !armed_seen) || (!rx_autostart && start && start_valid)));
  wire reader_consume=lane_mode ? lane_rd_consume : packet_mode ? packet_grant : state>=READ0 && state<=READ3 && rd_valid;
  wire fire=state==FIRE;
  wire [7:0] temporal_events={temporal_tx_left==0,(packet_mode ? packet_stop : frame_tx_done),rx0[0],(seq_event_enable[1] ? seq_events[1] : temporal_pins[1]),(seq_event_enable[0] ? seq_events[0] : temporal_pins[0]),(packet_mode ? (packet_grant && !packet_started) : finished[0]),temporal_tick,1'b1};
  wire temporal_abort=(packet_mode ? packet_done && packet_error : frame_tx_done && frame_tx_error) || (temporal_request && frame_tx_active) ||
    (lane_b_done && lane_b_error);
  grid_sequencer sequencer(clk,rst_n,arm && temporal_mode && !lane_mode && configured,
    seq_valid && seq_addr>=96 && seq_addr<=111,seq_addr[3:0],seq_data,
    seq_valid && seq_addr==91 && seq_data[1],host_start,temporal_abort,temporal_entry,temporal_events,
    sequencer_actions,temporal_halting,temporal_active,temporal_done,temporal_error,temporal_state,temporal_programmed,
    paging,temporal_idle,seq_loading,seq_load_page,page_row_we,page_row_addr,page_row_data,page_done);
  // ---- lane core (lane mode): controller, timers, coded shifter, CRC
  wire lane_owns_port,lane_resp_pending,lane_mem_req,lane_wr_valid,lane_rd_want,lane_ctl_loading,core_stream_fault;
  wire [9:0] lane_mem_addr;wire [7:0] lane_wr_data;
  wire [2:0] core_out_value,core_out_enable;
  reg [10:0] lane_left;
  always @(posedge clk) begin
    if(!rst_n || !arm) lane_left<=0;
    else if(lane_mode && host_start) lane_left<=lane_reader_go ? tx_length : 11'd0;
    else if(lane_rd_consume) lane_left<=lane_left-1'b1;
  end
  wire [15:0] timer0_captured,timer1_captured;
  // A stream that can never deliver fails the lane instead of hanging it:
  // PUSH with the writer closed (capacity used), PULL with no bytes left;
  // so does a controller PULL/PUSH on a stream the coded shifter owns.
  wire lane_stream_fail=(lane_wr_valid && !wr_active) || (lane_rd_want && lane_left==0) || core_stream_fault;
  grid_lane_core #(.USE_MACRO(USE_MACRO)) lane_core(clk,rst_n,arm && configured && lane_mode,
    core_cfg_we,lane_leaf[21:16],lane_leaf[15:0],core_configured,
    lane_mode && host_start,(lane_b_done && lane_b_error) || lane_stream_fail,
    lane_mem_req,mem_ready[0] && lane_owns_port,lane_mem_addr,mem_rvalid[0],mem_rdata[7:0],lane_owns_port,lane_resp_pending,
    rd_valid,rd_data,lane_rd_consume,lane_rd_want,lane_wr_valid,lane_wr_data,wr_ready,core_stream_fault,
    temporal_pins,seq_events,core_out_value,core_out_enable,
    {{14'b0,rd_valid,wr_ready},{5'b0,rx_written},{5'b0,lane_left}},
    lane_ctl_active,lane_ctl_loading,lane_ctl_done,lane_ctl_error);
  wire unused_lane=&{1'b0,lane_ctl_loading};
  // The core's output values are also cell 6's local sources in lane mode.
  assign lane_actions={1'b0,core_out_value};
  grid_page_loader page_loader(clk,rst_n,seq_loading,seq_load_page,page_cfg[9:0],
    page_req,mem_ready[0] && page_owns_port,page_addr,mem_rvalid[0],mem_rdata[7:0],
    page_row_we,page_row_addr,page_row_data,page_ctx_we,page_ctx_data,page_done,page_owns_port,page_resp_pending);
  wire [2:0] grid_pin_out,grid_pin_oe;wire [1:0] grid_pin_edges;wire grid_ctx_word_ok;
  grid_core grid(clk,rst_n,arm && format_valid && route_valid && temporal_ready,
    cfg_leaves,
    fire,pin_in,txword0,txword1,rx0,rx1,busy[0],finished[0],busy[1],finished[1],grid_pin_out,grid_pin_oe,grid_configured,
    control_mode,temporal_actions,temporal_actions[3],temporal_tick,temporal_pins,contexts_configured,
    packet_mode,packet_running,packet_grant,rd_data,packet_left==1,packet_request,packet_stop,packet_configured,packet_tick,
    seq_events,seq_event_enable,page_ctx_we,page_ctx_data,
    host_start,lane_a_done && lane_a_error,lane_a_running,lane_b_active,lane_b_done,lane_b_error,
    grid_pin_edges,1'b0,3'b0,16'b0,grid_ctx_word_ok,timer0_captured,timer1_captured);
  // Lane mode drives the pins from the core directly (value and enable
  // lines, so open drain is a selection); every other mode from the grid.
  assign pin_out=lane_mode ? core_out_value : grid_pin_out;
  assign pin_oe=lane_mode ? core_out_enable & {3{arm && configured}} : grid_pin_oe;
  // Only the old grid lane read these (lane mode now runs the lane core).
  wire unused_grid_lane=&{1'b0,grid_pin_edges,grid_ctx_word_ok,timer0_captured,timer1_captured,busy};
  wire rx_event=rx_autostart && finished[format[4]];
  wire frame_write=!rx_autostart && (state==WRITE0 || state==WRITE1);
  wire writer_valid=lane_mode ? lane_wr_valid : rx_autostart ? rx_event : frame_write;
  wire [15:0] decoded_rx=(format[4] ? rx1 : rx0) >> format[12:9];
  wire [7:0] writer_input=lane_mode ? lane_wr_data : rx_autostart ? decoded_rx[7:0] :
    state==WRITE0 && format[3:2]==2 ? received[15:8] : received[7:0];
  // Explicit local stream links between the bank-adjacent FIFOs and the
  // shifter-side scheduler. They are combinational in this prototype.
  grid_stream_link #(.WIDTH(9)) reader_to_shifter({rd_valid_local,rd_data_local},{rd_valid,rd_data});
  grid_stream_link #(.WIDTH(1)) shifter_to_reader(reader_consume,reader_consume_local);
  grid_stream_link #(.WIDTH(9)) shifter_to_writer({writer_valid,writer_input},{writer_valid_local,writer_input_local});
  grid_stream_link #(.WIDTH(1)) writer_to_shifter(wr_ready_local,wr_ready);
  grid_stream_reader #(.DEPTH(2)) reader(clk,rst_n,arm && configured && !cancel && !lane_close && (!packet_mode || !packet_error || packet_start),reader_start,selected_tx_base,selected_tx_length,
    rd_req,mem_ready[1],rd_addr,mem_rvalid[1],mem_rdata[15:8],rd_valid_local,reader_consume_local,rd_data_local,
    rd_active,rd_done,rd_error,rd_queued,rd_outstanding);
  grid_stream_writer #(.DEPTH(2)) writer(clk,rst_n,arm && configured && !cancel && !lane_close,writer_start,selected_rx_base,selected_rx_capacity,
    writer_valid_local,wr_ready_local,writer_input_local,wr_req,mem_ready[2],wr_addr,wr_data,wr_active,wr_done,wr_error,wr_queued);
  wire stream_route_write=leaf_valid && (leaf_bank || leaf_addr==88);
  wire [2:0] stream_routes=leaf_bank ? {leaf_data[1],leaf_data[1],leaf_data[0]} : leaf_data[2:0];
  grid_stream_memory #(.USE_MACRO(USE_MACRO)) memory(clk,rst_n,arm,stream_route_write,stream_routes,{wr_addr[10],rd_addr[10]},
    {wr_req,rd_req,page_owns_port ? page_req : lane_owns_port ? lane_mem_req : host_req},{1'b1,1'b0,!page_owns_port && !lane_owns_port && host_we},
    {wr_addr[9:0],rd_addr[9:0],page_owns_port ? page_addr : lane_owns_port ? lane_mem_addr : host_addr},{wr_data,8'b0,host_wdata},mem_ready,mem_rvalid,mem_rdata);
  // A page load borrows the host port; the host link waits on ready.
  assign host_ready=mem_ready[0] && !page_owns_port && !lane_owns_port;
  assign host_rvalid=mem_rvalid[0] && !page_resp_pending && !lane_resp_pending;assign host_rdata=mem_rdata[7:0];
  // Compatibility outputs share the same generic transfer status.
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured) begin
      armed_seen<=0;cancel<=0;empty_wait<=0;state<=IDLE;remaining<=0;txword0<=0;txword1<=0;received<=0;
      frame_tx_done<=0;frame_tx_error<=0;frame_spi_done<=0;frame_spi_error<=0;rx_overflow<=0;rx_received<=0;rx_written<=0;
      finished0_seen<=0;finished1_seen<=0;received_seen<=0;
    end else begin
      frame_tx_done<=0;frame_spi_done<=0;cancel<=0;
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
          frame_tx_error<=0;frame_spi_error<=0;empty_wait<=0;finished0_seen<=0;finished1_seen<=0;received_seen<=0;
          if(!start_valid) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;end
          else begin remaining<=selected_tx_length;state<=READ0;end
        end
        READ0: if(rd_valid) begin
          remaining<=remaining-1'b1;
          if(format[1:0]==1) begin txword0<=({8'b0,rd_data} << format[8:5]) | ormask;state<=format[13] ? READ2 : FIRE;end
          else begin txword0[15:8]<=rd_data;state<=READ1;end
        end else if(rd_done) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
        READ1: if(rd_valid) begin remaining<=remaining-1'b1;txword0<=({txword0[15:8],rd_data} << format[8:5]) | ormask;state<=format[13] ? READ2 : FIRE;end
          else if(rd_done) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
        READ2: if(rd_valid) begin
          remaining<=remaining-1'b1;
          if(format[14]) begin txword1[15:8]<=rd_data;state<=READ3;end
          else begin txword1<={8'b0,rd_data};state<=FIRE;end
        end else if(rd_done) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
        READ3: if(rd_valid) begin remaining<=remaining-1'b1;txword1[7:0]<=rd_data;state<=FIRE;end
          else if(rd_done) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
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
            else begin state<=IDLE;frame_tx_done<=1;frame_spi_done<=1;end
          end
        end
        WRITE0: if(wr_ready) state<=format[3:2]==2 ? WRITE1 : (remaining!=0 ? READ0 : WAIT_WRITE);
          else if(wr_done || !wr_active) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
        WRITE1: if(wr_ready) state<=remaining!=0 ? READ0 : WAIT_WRITE;
          else if(wr_done || !wr_active) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
        WAIT_WRITE: if(wr_done) begin state<=IDLE;frame_tx_done<=1;frame_spi_done<=1;end
          else if(!wr_req && wr_queued==0) begin
            if(empty_wait) begin frame_tx_error<=1;frame_spi_error<=1;frame_tx_done<=1;frame_spi_done<=1;cancel<=1;state<=IDLE;end
            else empty_wait<=1;
          end else empty_wait<=0;
        default:state<=IDLE;
      endcase
    end
  end
`ifdef GRID_STREAM_ASSERT
  // Start a coded stream on its selected shift event, and report a missing
  // byte at a burst boundary rather than silently ending the packet.
  assert property (@(posedge clk) disable iff(!rst_n || !arm || !configured || !packet_mode)
    packet_grant && !packet_started |-> packet_tick);
  assert property (@(posedge clk) disable iff(!rst_n || !arm || !configured || !packet_mode)
    packet_running && packet_started && packet_request && !rd_valid && packet_left!=0 |=> packet_error && packet_done);
  assert property (@(posedge clk) disable iff(!rst_n || !arm || !configured || !packet_mode)
    packet_grant |-> packet_left!=0);
`endif
  wire unused=&{1'b0,spi_source_addr,spi_dest_addr,rd_active,rd_error,rd_outstanding,wr_active,wr_error,temporal_state};
endmodule
`default_nettype wire
