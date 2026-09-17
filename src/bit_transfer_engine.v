`default_nettype none

// Protocol-neutral autonomous bit transfer plus a VM-driven shift path.
// Autonomous mode owns TX/CLK pin drive (push-pull or open-drain), optional
// clock-stretch wait, and CPOL/CPHA-style sample phase. Manual load/shift
// keeps UART-style bit bang working on the same shift register.
module bit_transfer_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Manual shift path (UART / bit-bang)
    input  wire        load,
    input  wire        shift_enable,
    input  wire        shift_right,
    input  wire        serial_in,
    input  wire [15:0] parallel_in,
    input  wire [4:0]  bit_count,
    output wire        serial_out,
    output wire [15:0] parallel_out,
    output wire        shift_done,

    // Autonomous transfer control
    input  wire        start,
    input  wire [3:0]  cfg_bit_count_m1,
    input  wire        cfg_msb_first,
    input  wire        cfg_clk_idle,
    input  wire        cfg_sample_phase,
    input  wire        cfg_tx_open_drain,
    input  wire        cfg_clk_open_drain,
    input  wire        cfg_wait_clk_high,
    input  wire [2:0]  cfg_tx_pin,
    input  wire [2:0]  cfg_rx_pin,
    input  wire [2:0]  cfg_clk_pin,
    input  wire [7:0]  cfg_half_period,
    input  wire [7:0]  pin_sampled,
    output wire        busy,
    output wire        done,

    // Logical pin overrides while busy
    output wire        drive_enable,
    output wire [7:0]  drive_out_value,
    output wire [7:0]  drive_out_mask,
    output wire [7:0]  drive_oe_value,
    output wire [7:0]  drive_oe_mask
);
  localparam ST_IDLE         = 3'd0;
  localparam ST_DRIVE_DATA   = 3'd1;
  localparam ST_CLOCK_ACTIVE = 3'd2;
  localparam ST_SAMPLE       = 3'd3;
  localparam ST_CLOCK_IDLE   = 3'd4;
  localparam ST_DONE         = 3'd5;

  reg [2:0]  state;
  reg [15:0] shift_register;
  reg [4:0]  bits_remaining;
  reg [4:0]  bits_total;
  reg        msb_first;
  reg        clk_idle;
  reg        sample_phase;
  reg        tx_open_drain;
  reg        clk_open_drain;
  reg        wait_clk_high;
  reg [2:0]  tx_pin;
  reg [2:0]  rx_pin;
  reg [2:0]  clk_pin;
  reg [7:0]  half_period;
  reg [7:0]  phase_counter;
  reg        tx_bit;
  reg        clk_level;
  reg        done_pulse;
  reg        active_sampled;

  wire [7:0] tx_mask  = 8'b1 << tx_pin;
  wire [7:0] clk_mask = 8'b1 << clk_pin;
  wire       rx_level = pin_sampled[rx_pin];
  wire       clk_sense = pin_sampled[clk_pin];
  wire       phase_done = phase_counter == 8'd0;
  wire       stretch_ok = !wait_clk_high || clk_sense;

  wire tx_out_level = tx_open_drain ? 1'b0 : tx_bit;
  wire tx_oe_level  = tx_open_drain ? ~tx_bit : 1'b1;
  wire clk_out_level = clk_open_drain ? 1'b0 : clk_level;
  wire clk_oe_level  = clk_open_drain ? ~clk_level : 1'b1;

  assign serial_out = shift_right ? shift_register[0] : shift_register[15];
  assign parallel_out = shift_register;
  assign shift_done = bits_remaining == 5'b0 && state == ST_IDLE;
  assign busy = state != ST_IDLE && state != ST_DONE;
  assign done = done_pulse;
  assign drive_enable = state != ST_IDLE && state != ST_DONE;
  assign drive_out_mask = drive_enable ? (tx_mask | clk_mask) : 8'b0;
  assign drive_oe_mask  = drive_out_mask;
  assign drive_out_value = (tx_out_level ? tx_mask : 8'b0) |
                           (clk_out_level ? clk_mask : 8'b0);
  assign drive_oe_value  = (tx_oe_level ? tx_mask : 8'b0) |
                           (clk_oe_level ? clk_mask : 8'b0);

  wire current_tx_bit = msb_first ? shift_register[15] : shift_register[0];
  wire [4:0] start_bits = {1'b0, cfg_bit_count_m1} + 5'd1;
  wire [4:0] align_shift = 5'd16 - start_bits;
  wire [15:0] aligned_tx = shift_register << align_shift;

  always @(posedge clk) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      shift_register <= 16'b0;
      bits_remaining <= 5'b0;
      bits_total <= 5'b0;
      msb_first <= 1'b0;
      clk_idle <= 1'b0;
      sample_phase <= 1'b0;
      tx_open_drain <= 1'b0;
      clk_open_drain <= 1'b0;
      wait_clk_high <= 1'b0;
      tx_pin <= 3'b0;
      rx_pin <= 3'b0;
      clk_pin <= 3'b0;
      half_period <= 8'd1;
      phase_counter <= 8'b0;
      tx_bit <= 1'b1;
      clk_level <= 1'b0;
      done_pulse <= 1'b0;
      active_sampled <= 1'b0;
    end else begin
      done_pulse <= 1'b0;

      if (state == ST_IDLE && load) begin
        shift_register <= parallel_in;
        bits_remaining <= bit_count;
      end else if (state == ST_IDLE && shift_enable && bits_remaining != 5'b0) begin
        if (shift_right)
          shift_register <= {serial_in, shift_register[15:1]};
        else
          shift_register <= {shift_register[14:0], serial_in};
        bits_remaining <= bits_remaining - 1'b1;
      end

      case (state)
        ST_IDLE: begin
          if (start) begin
            msb_first <= cfg_msb_first;
            clk_idle <= cfg_clk_idle;
            sample_phase <= cfg_sample_phase;
            tx_open_drain <= cfg_tx_open_drain;
            clk_open_drain <= cfg_clk_open_drain;
            wait_clk_high <= cfg_wait_clk_high;
            tx_pin <= cfg_tx_pin;
            rx_pin <= cfg_rx_pin;
            clk_pin <= cfg_clk_pin;
            half_period <= (cfg_half_period == 8'b0) ? 8'd1 : cfg_half_period;
            bits_total <= start_bits;
            bits_remaining <= start_bits;
            clk_level <= cfg_clk_idle;
            if (cfg_msb_first) begin
              shift_register <= aligned_tx;
              tx_bit <= aligned_tx[15];
            end else
              tx_bit <= shift_register[0];
            phase_counter <= (cfg_half_period == 8'b0) ? 8'd0 :
                             (cfg_half_period - 8'd1);
            active_sampled <= 1'b0;
            state <= ST_DRIVE_DATA;
          end
        end

        ST_DRIVE_DATA: begin
          clk_level <= clk_idle;
          // CPHA=0: data valid while idle before the leading edge.
          // CPHA=1: data is launched on the leading edge in CLOCK_ACTIVE.
          if (!sample_phase)
            tx_bit <= current_tx_bit;
          active_sampled <= 1'b0;
          if (phase_done) begin
            phase_counter <= half_period - 8'd1;
            clk_level <= ~clk_idle;
            if (sample_phase)
              tx_bit <= current_tx_bit;
            state <= ST_CLOCK_ACTIVE;
          end else
            phase_counter <= phase_counter - 8'd1;
        end

        ST_CLOCK_ACTIVE: begin
          clk_level <= ~clk_idle;
          // sample_phase=0: capture once clock is active (and stretch released)
          if (stretch_ok && !sample_phase && !active_sampled) begin
            if (msb_first)
              shift_register <= {shift_register[14:0], rx_level};
            else
              shift_register <= {rx_level, shift_register[15:1]};
            active_sampled <= 1'b1;
          end
          if (stretch_ok) begin
            if (phase_done) begin
              phase_counter <= half_period - 8'd1;
              state <= ST_SAMPLE;
            end else
              phase_counter <= phase_counter - 8'd1;
          end
        end

        ST_SAMPLE: begin
          // Trailing edge occurs as the clock returns to idle.
          // sample_phase=1 captures here (second edge).
          if (sample_phase) begin
            if (msb_first)
              shift_register <= {shift_register[14:0], rx_level};
            else
              shift_register <= {rx_level, shift_register[15:1]};
          end
          clk_level <= clk_idle;
          state <= ST_CLOCK_IDLE;
        end

        ST_CLOCK_IDLE: begin
          clk_level <= clk_idle;
          if (phase_done) begin
            if (bits_remaining <= 5'd1) begin
              bits_remaining <= 5'b0;
              state <= ST_DONE;
            end else begin
              bits_remaining <= bits_remaining - 5'd1;
              phase_counter <= half_period - 8'd1;
              state <= ST_DRIVE_DATA;
            end
          end else
            phase_counter <= phase_counter - 8'd1;
        end

        ST_DONE: begin
          done_pulse <= 1'b1;
          if (msb_first)
            shift_register <= shift_register << (16 - bits_total);
          state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
