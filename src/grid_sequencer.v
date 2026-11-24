`default_nettype none
// Generic Moore sequencer. Configuration is a 16-row register table, loaded
// while disabled; there is no SRAM or instruction fetch in its execution path.
// Each row is {halt, false_next[3:0], true_next[3:0], event[2:0], action[3:0]}.
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
  output wire [15:0] programmed
);
  reg [15:0] rows [0:15];
  reg [15:0] written;
  wire [15:0] row=rows[state];
  wire [3:0] next_state=events[row[6:4]] ? row[10:7] : row[14:11];
  assign programmed=written;
  assign actions=(enable && active && written[state]) ? row[3:0] : 4'b0000;
  assign halting=enable && active && written[state] && row[15];

  always @(posedge clk) begin
    if(!rst_n) begin
      written<=0; active<=0; done<=0; error<=0; state<=0;
    end else begin
      if(!enable) begin
        active<=0; done<=0; error<=0; state<=0;
        if(clear_program) written<=0;
        else if(cfg_we) begin rows[cfg_addr]<=cfg_data;written[cfg_addr]<=1;end
      end else begin
        done<=0;
        if(active && abort) begin active<=0;done<=1;error<=1;end
        else if(start && !active) begin
          error<=0;
          if(!written[entry]) begin error<=1;done<=1;end
          else begin state<=entry;active<=1;end
        end else if(active) begin
          if(row[15]) begin active<=0;done<=1;error<=row[2];end
          else if(!written[next_state]) begin active<=0;done<=1;error<=1;end
          else state<=next_state;
        end
      end
    end
  end
`ifdef GRID_SEQUENCER_ASSERT
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    active |-> written[state]);
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    active && !abort && !row[15] && next_state==state |=> abort || $stable(actions));
  assert property (@(posedge clk) disable iff(!rst_n || !enable)
    enable && cfg_we |=> $stable(programmed));
`endif
endmodule
`default_nettype wire
