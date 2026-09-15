`default_nettype none

// Synchronous nibble-command host interface. Commands are presented on host_in
// for one clock and separated by 8'h00. Program and payload bytes are assembled
// from low/high nibble commands so all eight pins remain available as host data.
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
    output wire       rx_pop,
    input  wire [7:0] rx_pop_data,
    input  wire       rx_empty,
    input  wire       engine_halted
);
  reg [7:0] last_command;
  reg [9:0] address_register;
  reg [9:0] access_address_register;
  reg [7:0] program_data_register;
  reg [7:0] tx_data_register;
  reg [7:0] output_register;
  reg engine_enable_register;
  reg program_write_register;
  reg program_read_register;
  reg tx_push_register;
  reg rx_pop_register;
  reg read_pending;

  wire command_valid = host_in != 8'h00 && host_in != last_command;
  wire [3:0] command = host_in[7:4];
  wire [3:0] payload = host_in[3:0];

  assign host_out = output_register;
  assign engine_enable = engine_enable_register;
  assign program_enable = program_write_register | program_read_register;
  assign program_write = program_write_register;
  assign program_read = program_read_register;
  assign program_address = access_address_register;
  assign program_write_data = program_data_register;
  assign program_write_mask = 8'hff;
  assign tx_push = tx_push_register;
  assign tx_push_data = tx_data_register;
  assign rx_pop = rx_pop_register;

  always @(posedge clk) begin
    if (!rst_n) begin
      last_command <= 8'h00;
      address_register <= 10'b0;
      access_address_register <= 10'b0;
      program_data_register <= 8'b0;
      tx_data_register <= 8'b0;
      output_register <= 8'b0;
      engine_enable_register <= 1'b0;
      program_write_register <= 1'b0;
      program_read_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;
      read_pending <= 1'b0;
    end else begin
      program_write_register <= 1'b0;
      program_read_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;

      if (engine_halted)
        engine_enable_register <= 1'b0;

      if (read_pending) begin
        output_register <= program_read_data;
        read_pending <= 1'b0;
      end

      if (host_in == 8'h00)
        last_command <= 8'h00;
      else if (command_valid) begin
        last_command <= host_in;
        case (command)
          4'h1: address_register[3:0] <= payload;
          4'h2: address_register[7:4] <= payload;
          4'h3: address_register[9:8] <= payload[1:0];
          4'h4: program_data_register[3:0] <= payload;
          4'h5: begin
            program_data_register[7:4] <= payload;
            if (!engine_enable_register) begin
              access_address_register <= address_register;
              program_write_register <= 1'b1;
              address_register <= address_register + 1'b1;
            end
          end
          4'h6: tx_data_register[3:0] <= payload;
          4'h7: begin
            tx_data_register[7:4] <= payload;
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
            if (!engine_enable_register) begin
              access_address_register <= address_register;
              program_read_register <= 1'b1;
              read_pending <= 1'b1;
            end
          end
          default: output_register <= output_register;
        endcase
      end
    end
  end
endmodule

`default_nettype wire
