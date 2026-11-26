`default_nettype none
// Generic Moore sequencer. The 16-row register table is one page of the
// program. Configuration loads it while disabled. With paging enabled, the
// program and its alternate contexts live in SRAM as 16-row pages; start loads
// page 0 and a page row loads another page, so execution inside a page never
// waits on memory. Each row is {halt, false_next[3:0], true_next[3:0],
// event[2:0], action[3:0]}. A halt row with bit 14 set is a page row:
// {1,1,2'b00,page[3:0],entry[3:0],action[3:0]}. Its action is held while the
// page loads, then execution continues at entry in the new page.
// A halt row with bit 14 set and mode[13:12] nonzero is a descriptor that
// covers two rows of work and then falls through to the next row:
//   mode 01 phases: {1,1,01,a0[3:0],a1[3:0],event[2:0],0} drives a0 until
//     the event, then a1 until the event, then continues at the next row.
//   mode 10 entry-wait: {1,1,10,pulse[3:0],hold[3:0],event[2:0],0} drives
//     pulse for one clock, then hold until the event, then the next row.
// Each is cycle-for-cycle equal to the two plain rows it replaces. Mode 11,
// bit 0, and falling through row 15 or into an unwritten row halt with error.
// On each active clock, branch on events[event]. A self-branch waits without
// changing actions. A halt row reports action bit 2 as the terminal error
// flag. Events and actions are generic fabric signals; their
// protocol meaning comes from the compiler's static configuration.
module grid_sequencer(
  input wire clk, rst_n, enable,
  input wire cfg_we, input wire [3:0] cfg_addr, input wire [15:0] cfg_data,
  input wire clear_program, input wire start, input wire abort, input wire [3:0] entry,
  input wire [7:0] events,
  output wire [3:0] actions,
  output wire halting,
  output reg active, done, error,
  output reg [3:0] state,
  output wire [15:0] programmed,
  input wire paging, input wire [3:0] idle_actions,
  output reg loading, output reg [3:0] load_page,
  input wire load_we, input wire [3:0] load_addr, input wire [15:0] load_data, input wire load_done
);
  reg [15:0] rows [0:15];
  reg [15:0] written;
  wire [15:0] row=rows[state];
  wire [3:0] next_state=events[row[6:4]] ? row[10:7] : row[14:11];
  assign programmed=written;
  reg [3:0] load_entry,load_actions;
  reg phase;
  wire page_row=row[15] && row[14] && row[13:12]==2'b00;
  wire descriptor=row[15] && row[14] && row[13:12]!=2'b00;
  wire descriptor_bad=row[13:12]==2'b11 || row[0];
  wire descriptor_event=events[row[3:1]];
  wire [3:0] descriptor_next=state+1'b1;
  wire [3:0] row_actions=!descriptor ? row[3:0] : phase ? row[7:4] : row[11:8];
  assign actions=!(enable && active) ? 4'b0000 : loading ? load_actions : written[state] ? row_actions : 4'b0000;
  assign halting=enable && active && !loading && written[state] && row[15] && !row[14];

  always @(posedge clk) begin
    if(!rst_n) begin
      written<=0; active<=0; done<=0; error<=0; state<=0; loading<=0; load_page<=0; load_entry<=0; load_actions<=0; phase<=0;
    end else begin
      if(!enable) begin
        active<=0; done<=0; error<=0; state<=0; loading<=0; phase<=0;
        if(clear_program) written<=0;
        else if(cfg_we) begin rows[cfg_addr]<=cfg_data;written[cfg_addr]<=1;end
      end else begin
        done<=0;
        if(load_we) begin rows[load_addr]<=load_data;written[load_addr]<=1;end
        if(active && abort) begin active<=0;done<=1;error<=1;loading<=0;phase<=0;end
        else if(start && !active) begin
          error<=0;phase<=0;
          if(paging) begin active<=1;loading<=1;load_page<=0;load_entry<=entry;load_actions<=idle_actions;end
          else if(!written[entry]) begin error<=1;done<=1;end
          else begin state<=entry;active<=1;end
        end else if(active && loading) begin
          if(load_done) begin loading<=0;state<=load_entry;end
        end else if(active) begin
          if(descriptor) begin
            if(descriptor_bad) begin active<=0;done<=1;error<=1;phase<=0;end
            else if(!phase) begin if(row[13] || descriptor_event) phase<=1;end
            else if(descriptor_event) begin
              phase<=0;
              if(state==4'd15 || !written[descriptor_next]) begin active<=0;done<=1;error<=1;end
              else state<=descriptor_next;
            end
          end
          else if(page_row) begin
            if(!paging || row[13:12]!=0) begin active<=0;done<=1;error<=1;end
            else begin loading<=1;load_page<=row[11:8];load_entry<=row[7:4];load_actions<=row[3:0];end
          end
          else if(row[15]) begin active<=0;done<=1;error<=row[2];end
          else if(!written[next_state]) begin active<=0;done<=1;error<=1;end
          else state<=next_state;
        end
      end
    end
  end
`ifdef GRID_SEQUENCER_ASSERT
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    active && !loading |-> written[state]);
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    loading |-> active);
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    active && !loading && !abort && !row[15] && next_state==state |=> abort || $stable(actions));
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    phase |-> active && !loading && descriptor);
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    enable && cfg_we |=> $stable(programmed));
`endif
endmodule
`default_nettype wire

`default_nettype none
// Loads one sequencer page from SRAM: 16 rows then 5 alternate-context words,
// little-endian, at base + 64*page (10-bit address, wrapping). Reads are
// ordered with a fixed one-clock return and no backpressure. Rows are written
// as they arrive; the five contexts are committed together on the last byte
// so validity checks never see a partly loaded context set. Dropping `load`
// cancels; a response still in flight is ignored.
module grid_page_loader(
  input wire clk,rst_n,load,input wire [3:0] page,input wire [9:0] base,
  output wire req,input wire ready,output wire [9:0] addr,
  input wire rvalid,input wire [7:0] rdata,
  output wire row_we,output wire [3:0] row_addr,output wire [15:0] row_data,
  output wire ctx_we,output wire [79:0] ctx_data,
  output reg done,output wire owns_port,output reg resp_pending);
  localparam [5:0] BYTES=6'd42;
  reg active,started;reg [5:0] sent,got;reg [7:0] low;reg [63:0] ctx_buf;
  wire issue=req && ready;
  assign req=active && sent!=BYTES;
  assign addr=base+{page,6'b0}+{4'b0,sent};
  assign owns_port=active;
  // Each odd byte completes a word, written straight from the return data.
  wire word_in=active && resp_pending && rvalid && got[0];
  assign row_we=word_in && got<6'd32;assign row_addr=got[4:1];assign row_data={rdata,low};
  assign ctx_we=word_in && got==6'd41;assign ctx_data={rdata,low,ctx_buf};
  always @(posedge clk) begin
    done<=0;
    // Tracks the port even across a cancel, so a late response is never
    // mistaken for a host read.
    resp_pending<=rst_n && issue;
    if(!rst_n || !load) begin active<=0;started<=0;sent<=0;got<=0;end
    else begin
      if(!started) begin active<=1;started<=1;sent<=0;got<=0;end
      if(issue) sent<=sent+1'b1;
      if(active && resp_pending && rvalid) begin
        got<=got+1'b1;
        if(!got[0]) low<=rdata;
        else if(got>=6'd32 && got!=6'd41) ctx_buf[(got-6'd33)*8+:16]<={rdata,low};
        else if(got==6'd41) begin active<=0;done<=1;end
      end
    end
  end
endmodule
`default_nettype wire
