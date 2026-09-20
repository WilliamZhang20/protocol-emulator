`default_nettype none

module gpio_ownership_properties;
  (* gclk *) reg formal_timestep;
  reg clk = 1'b0;
  always @(posedge formal_timestep) clk <= !clk;
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyseq *) reg [7:0] pin_in;
  (* anyseq *) reg map_write;
  (* anyseq *) reg [2:0] logical_pin;
  (* anyseq *) reg [2:0] physical_pin;
  (* anyseq *) reg [7:0] action_claim;
  (* anyseq *) reg action_drive_enable;
  (* anyseq *) reg [7:0] action_out_value;
  (* anyseq *) reg [7:0] action_out_mask;
  (* anyseq *) reg [7:0] action_oe_value;
  (* anyseq *) reg [7:0] action_oe_mask;
  (* anyseq *) reg [2:0] selected_pin;
  (* anyseq *) reg gpio_bit_value;
  (* anyseq *) reg oe_bit_value;
  (* anyseq *) reg execute_gpio_write;
  (* anyseq *) reg execute_oe_write;
  (* anyseq *) reg execute_shift_out;
  (* anyseq *) reg sideset_apply;
  (* anyseq *) reg [2:0] sideset_pin;
  (* anyseq *) reg sideset_val;

  wire [7:0] pin_claim;
  wire output_write;
  wire [7:0] output_value;
  wire [7:0] output_mask;
  wire [7:0] oe_value;
  wire [7:0] oe_mask;
  wire [7:0] pin_out;
  wire [7:0] pin_oe;
  wire [7:0] sampled;
  wire [7:0] timed;
  wire [23:0] mapping_snapshot;
  wire [7:0] rising;
  wire [7:0] falling;
  wire compare_match;

  gpio_arbiter arb (
      .action_claim(action_claim),
      .action_drive_enable(action_drive_enable),
      .action_out_value(action_out_value),
      .action_out_mask(action_out_mask),
      .action_oe_value(action_oe_value),
      .action_oe_mask(action_oe_mask),
      .selected_pin(selected_pin),
      .gpio_bit_value(gpio_bit_value), .oe_bit_value(oe_bit_value),
      .execute_gpio_write(execute_gpio_write),
      .execute_oe_write(execute_oe_write),
      .execute_shift_out(execute_shift_out),
      .sideset_apply(sideset_apply),
      .sideset_pin(sideset_pin), .sideset_val(sideset_val),
      .pin_claim(pin_claim), .gpio_output_write(output_write),
      .gpio_value(output_value), .gpio_output_mask(output_mask),
      .gpio_oe_value(oe_value), .gpio_oe_mask(oe_mask)
  );

  gpio_datapath gpio (
      .clk(clk), .rst_n(rst_n), .pin_in(pin_in),
      .pin_out(pin_out), .pin_oe(pin_oe),
      .map_write(map_write), .logical_pin(logical_pin),
      .physical_pin(physical_pin), .output_write(output_write),
      .output_value(output_value), .output_mask(output_mask),
      .oe_value(oe_value), .oe_mask(oe_mask),
      .compare_value(8'b0), .compare_mask(8'b0),
      .sampled_value(sampled), .timed_value(timed),
      .mapping_snapshot(mapping_snapshot),
      .rising_edges(rising), .falling_edges(falling),
      .compare_match(compare_match)
  );

  integer i;
  integer j;
  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (rst_n) begin
      // The producer may only drive pins it reserved. This is the action
      // engine/gpio arbiter interface contract, not an assumption about
      // CPU writes or physical mapping.
      assume((action_out_mask & ~action_claim) == 0);
      assume((action_oe_mask & ~action_claim) == 0);
      assert(pin_claim == action_claim);
      assert((output_mask & action_claim) ==
          (action_drive_enable ? action_out_mask : 8'b0));
      assert((oe_mask & action_claim) ==
          (action_drive_enable ? action_oe_mask : 8'b0));
      if (action_drive_enable) begin
        assert((output_value & action_out_mask) ==
               (action_out_value & action_out_mask));
        assert((oe_value & action_oe_mask) ==
               (action_oe_value & action_oe_mask));
      end
      for (i = 0; i < 8; i = i + 1)
        for (j = i + 1; j < 8; j = j + 1)
          assert(mapping_snapshot[3*i +: 3] != mapping_snapshot[3*j +: 3]);

      cover(map_write && logical_pin != physical_pin);
      cover(action_claim[selected_pin] && execute_gpio_write);
    end
  end
  wire _unused = &{pin_out, pin_oe, sampled, timed, rising, falling,
                   compare_match, sideset_val, 1'b0};
endmodule

`default_nettype wire
