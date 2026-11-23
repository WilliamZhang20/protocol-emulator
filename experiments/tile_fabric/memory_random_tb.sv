`timescale 1ns/1ps
`default_nettype none
// Black-box reference memory and handshake scoreboard; both bank backends see
// identical requests. Requesters hold unaccepted requests across cycles.
module memory_random_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0;
  reg [1:0] cfg_routes=0, req=0, we=0;
  reg [19:0] addr=0;
  reg [15:0] wdata=0;
  wire [1:0] ready, valid, macro_ready, macro_valid;
  wire [15:0] rdata, macro_data;
  experiment_memory_fabric #(.USE_MACRO(0)) behavioral(clk,rst_n,arm,cfg_we,cfg_routes,
      req,we,addr,wdata,ready,valid,rdata);
  experiment_memory_fabric #(.USE_MACRO(1)) macro_backed(clk,rst_n,arm,cfg_we,cfg_routes,
      req,we,addr,wdata,macro_ready,macro_valid,macro_data);
  memory_contract_assertions check_behavioral(clk,rst_n,arm,cfg_we,cfg_routes,req,we,addr,wdata,ready,valid);
  memory_contract_assertions check_macro(clk,rst_n,arm,cfg_we,cfg_routes,req,we,addr,wdata,macro_ready,macro_valid);
  reg [7:0] model [0:1][0:1023];
  reg initialized [0:1][0:1023];
  reg [1:0] model_routes=0, accepted=0, expected_valid=0, expected_known=0;
  reg [15:0] expected_data=0;
  integer last_winner[0:1];
  integer seed=32'h5a31c827, reported_seed, junk, cycle, b, a, m;
  integer accepted_reads=0, accepted_writes=0, conflicts=0, simultaneous=0;
  integer reconfigs=0, armed_config_ignored=0, resets=0, check_known=0;
  reg [1:0] contenders, grant;
  initial begin
    if ($value$plusargs("SEED=%d", seed)) begin end
    reported_seed=seed;
    junk=$urandom(seed);
    for (b=0; b<2; b=b+1) begin
      last_winner[b]=-1;
      for (a=0; a<1024; a=a+1) initialized[b][a]=0;
    end
    // Each active requester either keeps its unaccepted request or generates
    // a new one. Disarm/reset explicitly cancels any unaccepted request.
    for (cycle=0; cycle<12000; cycle=cycle+1) begin
      @(negedge clk);
      rst_n=(cycle>=3 && (cycle%997)!=0);
      arm=rst_n && ($urandom_range(0,9)!=0);
      cfg_we=($urandom_range(0,5)==0);
      cfg_routes=2'($urandom_range(0,3));
      for (m=0; m<2; m=m+1) begin
        if (!rst_n || !arm) req[m]=0;
        else if (!req[m] || accepted[m]) begin
          req[m]=($urandom_range(0,3)!=0);
          we[m]=1'($urandom_range(0,1));
          addr[10*m +: 10]=10'($urandom_range(0,31));
          wdata[8*m +: 8]=8'($urandom_range(0,255));
        end
      end
      #1;
      if (ready!==macro_ready) $fatal(1,"seed %0d cycle %0d ready mismatch",seed,cycle);
      if (!rst_n || !arm) begin
        if (ready!==0) $fatal(1,"request accepted while disabled");
      end else begin
        for (b=0; b<2; b=b+1) begin
          contenders=0;
          for (m=0; m<2; m=m+1)
            if (req[m] && model_routes[m]==1'(b)) contenders[m]=1;
          grant=ready & contenders;
          if (contenders==0 && grant!=0) $fatal(1,"spurious grant");
          if ((contenders==1 || contenders==2) && grant!==contenders) $fatal(1,"uncontended request stalled");
          if (contenders==3) begin
            conflicts=conflicts+1;
            if (grant!==1 && grant!==2) $fatal(1,"invalid contested grant");
            if (last_winner[b]>=0 && grant[last_winner[b]]) $fatal(1,"round robin fairness failure");
          end
          if (grant!=0) last_winner[b]=grant[1] ? 1 : 0;
        end
        if (ready==3) simultaneous=simultaneous+1;
      end
      if (|(ready & ~req)) $fatal(1,"ready without request");
      accepted=ready & req;
      expected_valid=0; expected_known=0; expected_data=0;
      if (rst_n) for (m=0; m<2; m=m+1) if (accepted[m]) begin
        b=int'(model_routes[m]); a=int'(addr[10*m +: 10]);
        if (we[m]) begin
          model[b][a]=wdata[8*m +: 8]; initialized[b][a]=1;
          accepted_writes=accepted_writes+1;
        end else begin
          expected_valid[m]=1; expected_known[m]=initialized[b][a];
          if (initialized[b][a]) expected_data[8*m +: 8]=model[b][a];
          accepted_reads=accepted_reads+1;
        end
      end
      if (!rst_n) begin
        model_routes=0; last_winner[0]=-1; last_winner[1]=-1; resets=resets+1;
      end else if (!arm && cfg_we) begin model_routes=cfg_routes; reconfigs=reconfigs+1; end
      else if (arm && cfg_we) armed_config_ignored=armed_config_ignored+1;
      @(posedge clk); #1;
      if (valid!==expected_valid || macro_valid!==expected_valid)
        $fatal(1,"seed %0d cycle %0d response valid mismatch: got %b/%b expected %b",seed,cycle,valid,macro_valid,expected_valid);
      for (m=0; m<2; m=m+1) if (expected_valid[m] && expected_known[m]) begin
        check_known=check_known+1;
        if (rdata[8*m +: 8]!==expected_data[8*m +: 8] || macro_data[8*m +: 8]!==expected_data[8*m +: 8])
          $fatal(1,"seed %0d cycle %0d requester %0d data mismatch",seed,cycle,m);
      end
    end
    if (accepted_reads<1000 || accepted_writes<1000 || conflicts<1000 || simultaneous<1000 ||
        reconfigs<10 || armed_config_ignored<100 || resets<4 || check_known<1000)
      $fatal(1,"insufficient randomized coverage");
    $display("PASS: randomized seed=%0d cycles=%0d reads=%0d writes=%0d known_reads=%0d conflicts=%0d parallel=%0d reconfigs=%0d resets=%0d",reported_seed,cycle,accepted_reads,accepted_writes,check_known,conflicts,simultaneous,reconfigs,resets);
    $finish;
  end
endmodule
`default_nettype wire
