`default_nettype none

// Owns XFER pin claims and merges VM vs engine GPIO updates so unclaimed pins
// stay writable while a transfer runs.
module gpio_arbiter (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire       force_clear,
    input  wire       bit_xfer_start,
    input  wire       bit_xfer_done,
    input  wire [7:0] start_claim,
    input  wire [2:0] selected_pin,
    input  wire       gpio_bit_value,
    input  wire       oe_bit_value,
    input  wire       execute_gpio_write,
    input  wire       execute_oe_write,
    input  wire       execute_shift_out,
    input  wire       engine_drive_enable,
    input  wire [7:0] engine_out_value,
    input  wire [7:0] engine_out_mask,
    input  wire [7:0] engine_oe_value,
    input  wire [7:0] engine_oe_mask,
    output reg  [7:0] pin_claim,
    output wire       gpio_output_write,
    output wire [7:0] gpio_value,
    output wire [7:0] gpio_output_mask,
    output wire [7:0] gpio_oe_value,
    output wire [7:0] gpio_oe_mask
);
  wire [7:0] selected_pin_mask = 8'b1 << selected_pin;
  wire [7:0] vm_pin_mask = selected_pin_mask & ~pin_claim;
  wire       vm_output_write =
      execute_gpio_write || execute_oe_write || execute_shift_out;

  wire [7:0] vm_out_value = gpio_bit_value ? selected_pin_mask : 8'b0;
  wire [7:0] vm_out_mask = vm_output_write ?
      ((execute_gpio_write || execute_shift_out) ? vm_pin_mask : 8'b0) : 8'b0;
  wire [7:0] vm_oe_mask =
      (vm_output_write && execute_oe_write) ? vm_pin_mask : 8'b0;
  wire [7:0] vm_oe_value = oe_bit_value ? selected_pin_mask : 8'b0;

  assign gpio_output_write = vm_output_write || engine_drive_enable;
  assign gpio_value =
      (vm_out_value & vm_out_mask) |
      (engine_drive_enable ? engine_out_value : 8'b0);
  assign gpio_output_mask =
      vm_out_mask | (engine_drive_enable ? engine_out_mask : 8'b0);
  assign gpio_oe_value =
      (vm_oe_value & vm_oe_mask) |
      (engine_drive_enable ? engine_oe_value : 8'b0);
  assign gpio_oe_mask =
      vm_oe_mask | (engine_drive_enable ? engine_oe_mask : 8'b0);

  always @(posedge clk) begin
    if (!rst_n) begin
      pin_claim <= 8'b0;
    end else if (!enable || force_clear) begin
      pin_claim <= 8'b0;
    end else begin
      if (bit_xfer_done)
        pin_claim <= 8'b0;
      if (bit_xfer_start)
        pin_claim <= start_claim;
    end
  end
endmodule

`default_nettype wire
