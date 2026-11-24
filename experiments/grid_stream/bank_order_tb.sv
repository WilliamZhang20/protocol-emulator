`timescale 1ns/1ps
module bank_order_tb;
  reg clk=0,rst_n=0,enable=0,start=0;wire req,valid,active,done,error;wire [10:0] addr;
  wire [7:0] data;wire [1:0] queued,outstanding;
  reg [3:0] slow_valid=0;reg [7:0] slow_data[0:3];reg fast_valid=0;reg [7:0] fast_data=0;
  wire rvalid=slow_valid[3] || fast_valid;
  wire [7:0] rdata=fast_valid ? fast_data : slow_data[3];
  grid_stream_reader reader(clk,rst_n,enable,start,11'd1022,11'd4,req,1'b1,addr,rvalid,rdata,
    valid,1'b1,data,active,done,error,queued,outstanding);
  always #5 clk=~clk;
  integer got=0,slow_returns=0,cycle;
  always @(posedge clk) begin
    if(!rst_n) begin slow_valid<=0;fast_valid<=0;end
    else begin
      slow_valid<={slow_valid[2:0],req && !addr[10]};
      slow_data[0]<=addr[7:0];slow_data[1]<=slow_data[0];slow_data[2]<=slow_data[1];slow_data[3]<=slow_data[2];
      fast_valid<=req && addr[10];fast_data<=addr[7:0]^8'h01;
      if(slow_valid[3]) slow_returns<=slow_returns+1;
      if(slow_valid[3] && fast_valid) $fatal(1,"simultaneous unbuffered returns");
      if(req && addr[10] && slow_returns!=2) $fatal(1,"next bank issued before prior reads drained");
      if(valid) begin
        case(got)
          0:if(data!==8'hfe) $fatal(1,"first byte");
          1:if(data!==8'hff) $fatal(1,"second byte");
          2:if(data!==8'h01) $fatal(1,"third byte");
          3:if(data!==8'h00) $fatal(1,"fourth byte");
          default:$fatal(1,"extra byte");
        endcase
        got<=got+1;
      end
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;enable=1;start=1;@(negedge clk);start=0;
    for(cycle=0;cycle<100 && !done;cycle=cycle+1) @(negedge clk);
    if(!done || error || got!=4) $fatal(1,"bank ordering incomplete");
    $display("PASS: cross-bank reader drains earlier slow-bank reads before issuing to a faster bank");
    $finish;
  end
endmodule
