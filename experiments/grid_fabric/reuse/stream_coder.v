`default_nettype none
// Integration probe for a reusable SRAM stream + coded shifter + CRC.  The
// tick and memory handshake are exposed so arbitration and rate are tested;
// no protocol-specific state machine or pre-encoded packet is used here.
module stream_coder_probe(
  input wire clk,rst_n,enable,start,tick,
  input wire [10:0] base,length,
  input wire shift_cfg_we,input wire [2:0] shift_cfg_addr,input wire [15:0] shift_cfg_data,
  input wire crc_cfg_we,input wire [2:0] crc_cfg_addr,input wire [15:0] crc_cfg_data,
  output wire mem_req,input wire mem_ready,output wire [10:0] mem_addr,
  input wire mem_rvalid,input wire [7:0] mem_rdata,
  output wire serial,output wire active,done,error,output wire [10:0] consumed
);
  reg running,done_r,error_r; reg [10:0] left,count;
  wire reader_valid,reader_active,reader_done,reader_error;
  wire [7:0] reader_data;wire [1:0] queued,outstanding;
  wire request,grant,stop,coder_active,crc_absorb,crc_bit,crc_emit,crc_tail;
  wire pulls,rx_request,rx_eop,rx_err,word,crc_out,crc_ok;
  wire [7:0] rx_byte;wire [15:0] rx_data,status;wire [31:0] crc_value;
  wire [63:0] lines={62'b0,tick,1'b0};
  assign grant=running && request && reader_valid;
  assign active=running;assign done=done_r;assign error=error_r;assign consumed=count;
  grid_stream_reader #(.DEPTH(2)) reader(clk,rst_n,enable && (!error_r || start),start,base,length,
    mem_req,mem_ready,mem_addr,mem_rvalid,mem_rdata,reader_valid,grant,reader_data,
    reader_active,reader_done,reader_error,queued,outstanding);
  fabric_shifter coder(clk,rst_n,enable && running,shift_cfg_we,shift_cfg_addr,shift_cfg_data,
    2'b11,1'b0,lines,pulls,request,grant,reader_data,left==1,1'b0,rx_request,1'b0,crc_tail,
    rx_byte,rx_eop,rx_err,serial,coder_active,word,stop,rx_data,status,crc_absorb,crc_bit,crc_emit,1'b1);
  fabric_crc crc(clk,rst_n,enable && running,crc_cfg_we,crc_cfg_addr,crc_cfg_data,
    lines,{1'b0,crc_absorb},{1'b0,crc_bit},{1'b0,crc_emit},crc_out,crc_tail,crc_ok,crc_value);
  always @(posedge clk) begin
    if(!rst_n || !enable) begin running<=0;done_r<=0;error_r<=0;left<=0;count<=0;end
    else begin
      done_r<=0;
      if(start && !running) begin running<=1;error_r<=0;left<=length;count<=0;end
      else if(running) begin
        if(grant) begin left<=left-1'b1;count<=count+1'b1;end
        if((reader_done && reader_error) || (count!=0 && request && !reader_valid && left!=0)) begin
          running<=0;done_r<=1;error_r<=1;
        end else if(stop) begin running<=0;done_r<=1;error_r<=left!=0;end
      end
    end
  end
  wire unused=&{1'b0,reader_active,queued,outstanding,pulls,rx_request,rx_eop,rx_err,word,
                crc_out,crc_ok,rx_byte,rx_data,status,crc_value,coder_active};
endmodule
`default_nettype wire
