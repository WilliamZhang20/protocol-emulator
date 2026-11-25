`timescale 1ns/1ps
module sequencer_tb;
  reg clk=0, rst_n=0, enable=0, cfg_we=0, clear_program=0, start=0, abort=0;
  reg [3:0] cfg_addr=0, entry=0;
  reg [15:0] cfg_data=0;
  reg [7:0] events=8'b1;
  wire [3:0] actions,state;
  wire active,done,error,halting;
  wire [15:0] programmed;
  reg paging=0;integer nchk=0;
  wire loading,row_we,ctx_we,load_done,owns,resp_pending,req,ready;
  wire [3:0] load_page,row_addr;wire [15:0] row_data;wire [79:0] ctx_data;wire [9:0] addr;
  grid_sequencer dut(clk,rst_n,enable,cfg_we,cfg_addr,cfg_data,clear_program,start,abort,entry,
                     events,actions,halting,active,done,error,state,programmed,
                     paging,4'hc,loading,load_page,row_we,row_addr,row_data,load_done);
  // SRAM model: one-clock read return, no backpressure, random port stalls.
  reg [7:0] mem[0:1023];reg rvalid=0;reg [7:0] rdata=0;reg stall=0;reg [9:0] base=10'd100;
  reg [79:0] ctx_seen=0;integer ctx_commits=0;
  assign ready=req && !stall;
  always @(posedge clk) begin
    stall<=($random & 3)==0;
    rvalid<=ready;if(ready) rdata<=mem[addr];
    if(ctx_we) begin ctx_seen<=ctx_data;ctx_commits<=ctx_commits+1;end
  end
  grid_page_loader loader(clk,rst_n,loading,load_page,base,req,ready,addr,rvalid,rdata,
                          row_we,row_addr,row_data,ctx_we,ctx_data,load_done,owns,resp_pending);
  always #5 clk=~clk;
  initial begin #100000;$fatal(1,"timeout");end
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
  task automatic put_page(input [3:0] page,input [15:0] rows[16],input [15:0] ctx[5]);
    integer k;reg [9:0] a;
    for(k=0;k<16;k=k+1) begin a=base+page*64+2*k;mem[a]=rows[k][7:0];mem[a+1]=rows[k][15:8];end
    for(k=0;k<5;k=k+1) begin a=base+page*64+32+2*k;mem[a]=ctx[k][7:0];mem[a+1]=ctx[k][15:8];end
  endtask
  function automatic [15:0] page_row(input [3:0] page,input [3:0] to,input [3:0] action);
    return {2'b11,2'b00,page,to,action};
  endfunction
  task automatic wait_loaded;
    integer n;n=0;
    while(loading) begin tick();n=n+1;if(n>400) $fatal(1,"page load hung");end
  endtask
  task automatic check(input bit a,input [3:0] s,input [3:0] o,input bit d,input bit e);
    if(active!==a || state!==s || actions!==o || done!==d || error!==e)
      $fatal(1,"check #%0d: got active=%b state=%0d actions=%h done=%b error=%b",nchk,active,state,actions,done,error);
    nchk=nchk+1;
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
    // Paging: the program and contexts come from SRAM pages.
    begin
      reg [15:0] p0[16],p2[16],c0[5],c2[5];integer k;
      for(k=0;k<16;k=k+1) begin p0[k]=row(1,0,0,0,4);p2[k]=row(1,0,0,0,4);end
      p0[0]=row(0,1,1,0,1);                 // always -> 1, action 1
      p0[1]=page_row(2,3,5);                // load page 2, enter row 3, hold action 5
      p0[5]=row(1,0,0,0,2);                 // halt, no error
      p2[3]=row(0,3,4,1,9);                 // wait for event 1, action 9
      p2[4]=page_row(0,5,6);                // back to page 0 row 5
      for(k=0;k<5;k=k+1) begin c0[k]=16'h0100+k;c2[k]=16'h0200+k;end
      put_page(0,p0,c0);put_page(2,p2,c2);
    end
    @(negedge clk);enable=0;paging=1;events=1;tick();@(negedge clk);enable=1;
    launch(7);
    if(!loading || actions!==4'hc || !active) $fatal(1,"start must load page 0 holding idle actions");
    wait_loaded();
    if(ctx_commits!=1 || ctx_seen!=={16'h0104,16'h0103,16'h0102,16'h0101,16'h0100}) $fatal(1,"page 0 contexts");
    if(programmed!==16'hffff) $fatal(1,"page load marks every row");
    // entry 7 is a halt filler row in page 0
    check(1,7,4,0,0);tick();check(0,7,0,1,1);
    launch(0);wait_loaded();check(1,0,1,0,0);
    tick();check(1,1,5,0,0);
    tick();if(!loading || actions!==4'h5 || halting) $fatal(1,"page row holds its action while loading");
    wait_loaded();
    if(ctx_seen!=={16'h0204,16'h0203,16'h0202,16'h0201,16'h0200}) $fatal(1,"page 2 contexts");
    check(1,3,9,0,0);
    repeat(3) begin tick();check(1,3,9,0,0);end
    @(negedge clk);events[1]=1;tick();check(1,4,6,0,0);
    @(negedge clk);events[1]=0;tick();if(!loading || actions!==4'h6) $fatal(1,"second page load");
    wait_loaded();check(1,5,2,0,0);
    if(!halting) $fatal(1,"halt after page return");
    tick();check(0,5,0,1,0);
    // Abort during a load cancels it and fails closed.
    launch(0);repeat(3) tick();
    if(!loading) $fatal(1,"expected a load in progress");
    @(negedge clk);abort=1;tick();check(0,5,0,1,1); // state is not observed while loading
    @(negedge clk);abort=0;
    repeat(4) tick();if(owns) $fatal(1,"loader kept the port after cancel");
    // Page rows fail closed without paging or with reserved bits.
    @(negedge clk);enable=0;paging=0;tick();
    write_row(0,page_row(1,0,3));
    @(negedge clk);enable=1;launch(0);check(1,0,3,0,0);tick();check(0,0,0,1,1);
    @(negedge clk);enable=0;tick();
    begin reg [15:0] bad;bad=page_row(1,0,3)|16'h1000;mem[base]=bad[7:0];mem[base+1]=bad[15:8];end
    @(negedge clk);paging=1;enable=1;launch(0);
    wait_loaded();
    check(1,0,3,0,0);
    tick();check(0,0,0,1,1);
    $display("PASS: programmable sequencer waits, branches, halts and fails closed");
    $display("PASS: sequencer pages and contexts load from SRAM under port stalls");
    $finish;
  end
endmodule
