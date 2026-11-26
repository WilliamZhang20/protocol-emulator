`default_nettype none
// Prototype (FABRIC_REORG.md step 2): a two-event Moore sequencer as a cell
// resource. Row (19 bits): {halt[18], actions[17:14], event_a[13:11],
// next_a[10:7], event_b[6:4], next_b[3:0]}. Each active clock: if the row
// halts, finish (error = actions[2]); else if events[event_a] go to next_a;
// else if events[event_b] go to next_b; else stay. events[0] is always 1;
// events[7:1] are routed sinks. Actions come from the state register.
//
// LATCH=1 adds event storage: a routed pulse sets a flag that a row reads as
// the event; flags clear when the state changes (so a row waits for events
// from its own entry on, which replaces the lane controller's CLEAR),
// except pulses arriving on that same clock (other than the one taken),
// which are kept. LATCH=0 reads
// the routed lines directly.
module seq2 #(parameter LATCH=0)(
  input wire clk, rst_n, enable,
  input wire cfg_we, input wire [3:0] cfg_addr, input wire [18:0] cfg_data,
  input wire start, input wire [3:0] entry, input wire [3:0] idle_actions,
  input wire [7:1] events_in,
  output wire [3:0] actions,
  output reg active, done, error,
  output reg [3:0] state);
  reg [18:0] rows[0:15];
  reg [15:0] written;
  reg [7:1] flags;
  wire [18:0] row=rows[state];
  wire [7:0] ev={(LATCH ? (flags | events_in) : events_in),1'b1};
  wire take_a=ev[row[13:11]], take_b=ev[row[6:4]];
  wire [3:0] next=take_a ? row[10:7] : take_b ? row[3:0] : state;
  wire moving=active && !row[18] && next!=state;
  wire [2:0] taken=take_a ? row[13:11] : row[6:4];
  wire [7:0] taken_bit=8'd1 << taken;
  assign actions=active ? row[17:14] : idle_actions;
  integer i;
  always @(posedge clk) begin
    if(!rst_n) begin active<=0;done<=0;error<=0;state<=0;written<=0;flags<=0;end
    else begin
      done<=0;
      if(cfg_we && !enable) begin rows[cfg_addr]<=cfg_data;written[cfg_addr]<=1;end
      if(enable) begin
        if(start && !active) begin
          error<=0;flags<=0;
          if(!written[entry]) begin error<=1;done<=1;end
          else begin state<=entry;active<=1;end
        end else if(active) begin
          flags<=moving ? (events_in & ~taken_bit[7:1]) : (flags | events_in);
          if(row[18]) begin active<=0;done<=1;error<=row[16];end
          else if(next!=state) begin
            if(!written[next]) begin active<=0;done<=1;error<=1;end
            else state<=next;
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
