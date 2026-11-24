`timescale 1ns/1ps
module sequencer_tb;
  reg clk=0, rst_n=0, enable=0, cfg_we=0, clear_program=0, start=0, abort=0;
  reg [3:0] cfg_addr=0, entry=0;
  reg [15:0] cfg_data=0;
  reg [7:0] events=8'b1;
  wire [3:0] actions,state;
  wire active,done,error,halting;
  wire [15:0] programmed;
  grid_sequencer dut(clk,rst_n,enable,cfg_we,cfg_addr,cfg_data,clear_program,start,abort,entry,
                     events,actions,halting,active,done,error,state,programmed);
  always #5 clk=~clk;
  initial begin #10000;$fatal(1,"timeout");end
  function automatic [15:0] row(input bit halt,input [3:0] no,input [3:0] yes,
                                 input [2:0] event_id,input [3:0] action);
    return {halt,no,yes,event_id,action};
  endfunction
  task automatic tick;
    @(posedge clk);#1;
  endtask
  task automatic write_row(input [3:0] addr,input [15:0] value);
    @(negedge clk);cfg_we=1;cfg_addr=addr;cfg_data=value;
    tick();@(negedge clk);cfg_we=0;
  endtask
  task automatic launch(input [3:0] addr);
    @(negedge clk);entry=addr;start=1;tick();@(negedge clk);start=0;
  endtask
  task automatic check(input bit a,input [3:0] s,input [3:0] o,input bit d,input bit e);
    if(active!==a || state!==s || actions!==o || done!==d || error!==e)
      $fatal(1,"got active=%b state=%0d actions=%h done=%b error=%b",active,state,actions,done,error);
  endtask
  initial begin
    tick();@(negedge clk);rst_n=1;
    write_row(0,row(0,0,1,1,1)); // wait for event 1
    write_row(1,row(0,3,2,2,2)); // event 2 selects a branch
    write_row(2,row(0,4,4,0,4));
    write_row(3,row(0,4,4,0,8));
    write_row(4,row(1,0,0,0,11));
    if(programmed!==16'h001f) $fatal(1,"programmed bitmap");
    @(negedge clk);enable=1;
    launch(0);check(1,0,1,0,0);
    repeat(3) begin tick();check(1,0,1,0,0);end
    @(negedge clk);events[1]=1;tick();check(1,1,2,0,0);
    @(negedge clk);events[1]=0;tick();check(1,3,8,0,0);
    @(negedge clk);tick();check(1,4,11,0,0);
    if(!halting) $fatal(1,"halt indicator");
    @(negedge clk);tick();check(0,4,0,1,0);
    @(negedge clk);tick();check(0,4,0,0,0);
    // Configuration writes while enabled must not alter the program.
    @(negedge clk);cfg_we=1;cfg_addr=0;cfg_data=16'hffff;tick();
    @(negedge clk);cfg_we=0;events[1]=1;events[2]=1;
    launch(0);check(1,0,1,0,0);
    tick();check(1,1,2,0,0);
    @(negedge clk);tick();check(1,2,4,0,0);
    @(negedge clk);tick();check(1,4,11,0,0);
    @(negedge clk);tick();check(0,4,0,1,0);
    // Unprogrammed entry and unprogrammed transition fail closed.
    launch(9);check(0,4,0,1,1);
    @(negedge clk);enable=0;events=1;tick();
    write_row(5,row(0,6,6,0,3));
    @(negedge clk);enable=1;launch(5);check(1,5,3,0,0);
    tick();check(0,5,0,1,1);
    @(negedge clk);enable=0;tick();write_row(6,row(1,0,0,0,4));
    @(negedge clk);enable=1;launch(6);check(1,6,4,0,0);
    tick();check(0,6,0,1,1);
    @(negedge clk);events=1;launch(0);check(1,0,1,0,0);
    @(negedge clk);abort=1;tick();check(0,0,0,1,1);
    @(negedge clk);abort=0;
    @(negedge clk);enable=0;clear_program=1;tick();
    if(programmed!=0 || actions!=0) $fatal(1,"clear did not invalidate rows");
    @(negedge clk);clear_program=0;enable=1;launch(0);check(0,0,0,1,1);
    $display("PASS: programmable sequencer waits, branches, halts and fails closed");
    $finish;
  end
endmodule
