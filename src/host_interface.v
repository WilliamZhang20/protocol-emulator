`default_nettype none

// Synchronous nibble-command host interface. Commands are presented on host_in
// for one clock and separated by 8'h00. Program and payload bytes are assembled
// from low/high nibble commands so all eight pins remain available as host data.
//
// One low-nibble stage and one data register serve both program writes and
// TX pushes: a byte is committed by its high-nibble command, and the 8'h00
// that must follow every command keeps the two from overlapping. The address
// increments the cycle after an SRAM write, so the write sees it unchanged.
module host_interface (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] host_in,
    output wire [7:0] host_out,
    output wire       engine_enable,
    output wire       program_enable,
    output wire       program_write,
    output wire       program_read,
    output wire [9:0] program_address,
    output wire [7:0] program_write_data,
    output wire [7:0] program_write_mask,
    input  wire [7:0] program_read_data,
    output wire       tx_push,
    output wire [7:0] tx_push_data,
    input  wire       tx_full,
    input  wire [2:0] tx_level,
    output wire       rx_pop,
    input  wire [7:0] rx_pop_data,
    input  wire       rx_empty,
    input  wire [2:0] rx_level,
    input  wire       engine_halted
);
  reg       seen;              // a command was accepted since the last 8'h00
  reg [9:0] address_register;
  reg [3:0] low_nibble;
  reg [7:0] data_register;
  reg [7:0] output_register;
  reg engine_enable_register;
  reg program_write_register;
  reg program_read_register;
  reg tx_push_register;
  reg rx_pop_register;
  reg read_capture;            // SRAM data is valid the cycle after a read

  wire command_valid = host_in != 8'h00 && !seen;
  wire [3:0] command = host_in[7:4];
  wire [3:0] payload = host_in[3:0];

  assign host_out = output_register;
  assign engine_enable = engine_enable_register;
  assign program_enable = program_write_register | program_read_register;
  assign program_write = program_write_register;
  assign program_read = program_read_register;
  assign program_address = address_register;
  assign program_write_data = data_register;
  assign program_write_mask = 8'hff;
  assign tx_push = tx_push_register;
  assign tx_push_data = data_register;
  assign rx_pop = rx_pop_register;

  always @(posedge clk) begin
    if (!rst_n) begin
      seen <= 1'b0;
      address_register <= 10'b0;
      low_nibble <= 4'b0;
      data_register <= 8'b0;
      output_register <= 8'b0;
      engine_enable_register <= 1'b0;
      program_write_register <= 1'b0;
      program_read_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;
      read_capture <= 1'b0;
    end else begin
      program_write_register <= 1'b0;
      program_read_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;

      if (engine_halted)
        engine_enable_register <= 1'b0;

      // The SRAM registers its output on the edge that ends the read
      // cycle, so the data is captured one cycle after the read strobe.
      read_capture <= program_read_register;
      if (read_capture)
        output_register <= program_read_data;
      // Post-increment after a write has used the address.
      if (program_write_register)
        address_register <= address_register + 1'b1;

      if (host_in == 8'h00)
        seen <= 1'b0;
      else if (command_valid) begin
        seen <= 1'b1;
        case (command)
          4'h1: address_register[3:0] <= payload;
          4'h2: address_register[7:4] <= payload;
          4'h3: address_register[9:8] <= payload[1:0];
          4'h4, 4'h6: low_nibble <= payload;
          4'h5: begin
            data_register <= {payload, low_nibble};
            if (!engine_enable_register)
              program_write_register <= 1'b1;
          end
          4'h7: begin
            data_register <= {payload, low_nibble};
            if (!tx_full)
              tx_push_register <= 1'b1;
          end
          4'h8: begin
            if (payload[0])
              engine_enable_register <= 1'b1;
            if (payload[1])
              engine_enable_register <= 1'b0;
          end
          4'h9: begin
            if (!rx_empty) begin
              output_register <= rx_pop_data;
              rx_pop_register <= 1'b1;
            end
          end
          4'ha: output_register <= {
              engine_enable_register, engine_halted, tx_full, rx_empty, 4'b0
          };
          4'hb: begin
            if (!engine_enable_register)
              program_read_register <= 1'b1;
          end
          // Streaming aids: FIFO levels for polled drivers, and RX peek
          // without consuming.
          4'hc: output_register <= {
              tx_full, rx_empty, tx_level, rx_level
          };
          4'hd: begin
            if (!rx_empty)
              output_register <= rx_pop_data;
          end
          default: output_register <= output_register;
        endcase
      end
    end
  end
endmodule

`default_nettype wire
