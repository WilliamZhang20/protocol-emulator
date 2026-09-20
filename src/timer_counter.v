`default_nettype none

// Exact-cycle timer with optional autonomous (nonblocking) mode.
// Blocking waits keep count_enable high from the VM; async mode self-runs
// after load until expiry and pulses done_pulse once.
module timer_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,
    input  wire        count_enable,
    input  wire        async_start,
    input  wire [15:0] load_value,
    output wire [15:0] count_value,
    output wire        expired,
    output wire        busy,
    output wire        done_pulse
);
  reg [15:0] count;
  reg        async_run;
  reg        done_reg;

  assign count_value = count;
  assign expired = count == 16'b0;
  assign busy = async_run;
  assign done_pulse = done_reg;

  wire ticking = (count_enable || async_run) && count != 16'b0;

  always @(posedge clk) begin
    if (!rst_n) begin
      count <= 16'b0;
      async_run <= 1'b0;
      done_reg <= 1'b0;
    end else begin
      done_reg <= 1'b0;
      if (load) begin
        count <= load_value;
        async_run <= async_start && load_value != 16'b0;
        // A zero-length asynchronous timer completes immediately rather
        // than remaining busy forever with an already-expired counter.
        done_reg <= async_start && load_value == 16'b0;
      end else if (ticking) begin
        count <= count - 1'b1;
        if (count == 16'd1 && async_run) begin
          async_run <= 1'b0;
          done_reg <= 1'b1;
        end
      end
    end
  end
endmodule

`default_nettype wire
