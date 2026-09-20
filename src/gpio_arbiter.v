`default_nettype none

// Merges VM GPIO writes with the action region's claimed pins.
module gpio_arbiter (
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
    output wire [7:0] pin_claim,
    output wire       gpio_output_write,
    output wire [7:0] gpio_value,
    output wire [7:0] gpio_output_mask,
    output wire [7:0] gpio_oe_value,
    output wire [7:0] gpio_oe_mask
);
  wire [7:0] selected_pin_mask = 8'b1 << selected_pin;
  wire [7:0] vm_pin_mask = selected_pin_mask & ~action_claim;
  wire vm_output_write =
      execute_gpio_write || execute_oe_write || execute_shift_out;

  wire [7:0] vm_out_value = gpio_bit_value ? selected_pin_mask : 8'b0;
  wire [7:0] vm_out_mask = (execute_gpio_write || execute_shift_out) ?
      vm_pin_mask : 8'b0;
  wire [7:0] vm_oe_mask = execute_oe_write ? vm_pin_mask : 8'b0;
  wire [7:0] vm_oe_value = oe_bit_value ? selected_pin_mask : 8'b0;
  wire [7:0] sideset_pin_mask = (8'b1 << sideset_pin) & ~action_claim;
  // If the next CPU instruction also writes this pin, its explicit write
  // takes priority over the side-set prefix on that accepting edge.
  wire [7:0] sideset_out_mask = sideset_apply ?
      (sideset_pin_mask & ~vm_out_mask) : 8'b0;
  wire [7:0] sideset_out_value = sideset_val ? sideset_pin_mask : 8'b0;
  wire [7:0] res_out_mask = action_drive_enable ? action_out_mask : 8'b0;
  wire [7:0] res_oe_mask = action_drive_enable ? action_oe_mask : 8'b0;

  assign pin_claim = action_claim;
  assign gpio_output_write = vm_output_write || action_drive_enable || sideset_apply;
  assign gpio_value = (vm_out_value & vm_out_mask) |
      (action_out_value & res_out_mask) |
      (sideset_out_value & sideset_out_mask);
  assign gpio_output_mask = vm_out_mask | res_out_mask | sideset_out_mask;
  assign gpio_oe_value = (vm_oe_value & vm_oe_mask) |
      (action_oe_value & res_oe_mask);
  assign gpio_oe_mask = vm_oe_mask | res_oe_mask;
endmodule

`default_nettype wire
