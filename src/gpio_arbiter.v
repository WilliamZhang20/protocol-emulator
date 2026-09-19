`default_nettype none

// Owns XFER pin claims and merges VM vs resource GPIO updates so unclaimed
// pins stay writable. line_pair and action_engine claims are level-driven.
module gpio_arbiter (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,
    input  wire       force_clear,
    input  wire       bit_xfer_start,
    input  wire       bit_xfer_done,
    input  wire [7:0] start_claim,
    input  wire [7:0] line_claim,
    input  wire       line_drive_enable,
    input  wire [7:0] line_out_value,
    input  wire [7:0] line_out_mask,
    input  wire [7:0] line_oe_value,
    input  wire [7:0] line_oe_mask,
    input  wire [7:0] action_claim,
    input  wire       action_drive_enable,
    input  wire [7:0] action_out_value,
    input  wire [7:0] action_out_mask,
    input  wire [7:0] action_oe_value,
    input  wire [7:0] action_oe_mask,
    input  wire [2:0] selected_pin,
    input  wire       gpio_bit_value,
    input  wire       oe_bit_value,
    input  wire       execute_gpio_write,
    input  wire       execute_oe_write,
    input  wire       execute_shift_out,
    input  wire       sideset_apply,
    input  wire [2:0] sideset_pin,
    input  wire       sideset_val,
    input  wire       engine_drive_enable,
    input  wire [7:0] engine_out_value,
    input  wire [7:0] engine_out_mask,
    input  wire [7:0] engine_oe_value,
    input  wire [7:0] engine_oe_mask,
    output wire [7:0] pin_claim,
    output wire       gpio_output_write,
    output wire [7:0] gpio_value,
    output wire [7:0] gpio_output_mask,
    output wire [7:0] gpio_oe_value,
    output wire [7:0] gpio_oe_mask
);
  reg [7:0] xfer_claim;

  wire [7:0] selected_pin_mask = 8'b1 << selected_pin;
  wire [7:0] claimed = xfer_claim | line_claim | action_claim;
  wire [7:0] vm_pin_mask = selected_pin_mask & ~claimed;
  wire       vm_output_write =
      execute_gpio_write || execute_oe_write || execute_shift_out;

  wire [7:0] vm_out_value = gpio_bit_value ? selected_pin_mask : 8'b0;
  wire [7:0] vm_out_mask = vm_output_write ?
      ((execute_gpio_write || execute_shift_out) ? vm_pin_mask : 8'b0) : 8'b0;
  wire [7:0] vm_oe_mask =
      (vm_output_write && execute_oe_write) ? vm_pin_mask : 8'b0;
  wire [7:0] vm_oe_value = oe_bit_value ? selected_pin_mask : 8'b0;
  // Phase 6: side-set applies a simultaneous GPIO transition at instruction
  // start. Masked by claims like the VM path; ignored on owned pins.
  wire [7:0] sideset_pin_mask = (8'b1 << sideset_pin) & ~claimed;
  wire [7:0] sideset_out_mask = sideset_apply ? sideset_pin_mask : 8'b0;
  wire [7:0] sideset_out_value = sideset_val ? sideset_pin_mask : 8'b0;

  wire res_drive = engine_drive_enable || line_drive_enable || action_drive_enable;
  wire [7:0] res_out =
      (engine_drive_enable ? engine_out_value : 8'b0) |
      (line_drive_enable ? line_out_value : 8'b0) |
      (action_drive_enable ? action_out_value : 8'b0);
  wire [7:0] res_out_mask =
      (engine_drive_enable ? engine_out_mask : 8'b0) |
      (line_drive_enable ? line_out_mask : 8'b0) |
      (action_drive_enable ? action_out_mask : 8'b0);
  wire [7:0] res_oe =
      (engine_drive_enable ? engine_oe_value : 8'b0) |
      (line_drive_enable ? line_oe_value : 8'b0) |
      (action_drive_enable ? action_oe_value : 8'b0);
  wire [7:0] res_oe_mask =
      (engine_drive_enable ? engine_oe_mask : 8'b0) |
      (line_drive_enable ? line_oe_mask : 8'b0) |
      (action_drive_enable ? action_oe_mask : 8'b0);

  assign pin_claim = claimed;
  assign gpio_output_write = vm_output_write || res_drive || sideset_apply;
  assign gpio_value = (vm_out_value & vm_out_mask) | res_out |
      (sideset_out_value & sideset_out_mask);
  assign gpio_output_mask = vm_out_mask | res_out_mask | sideset_out_mask;
  assign gpio_oe_value = (vm_oe_value & vm_oe_mask) | res_oe;
  assign gpio_oe_mask = vm_oe_mask | res_oe_mask;

  always @(posedge clk) begin
    if (!rst_n) begin
      xfer_claim <= 8'b0;
    end else if (!enable || force_clear) begin
      xfer_claim <= 8'b0;
    end else begin
      if (bit_xfer_done)
        xfer_claim <= 8'b0;
      if (bit_xfer_start)
        xfer_claim <= start_claim;
    end
  end
endmodule

`default_nettype wire
