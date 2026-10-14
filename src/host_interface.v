`default_nettype none

// Host link. Each command byte {command, payload} is held on host_in for one
// clock and followed by 8'h00; a byte equal to the previous command is
// ignored until 8'h00 is seen. Program and TX bytes are assembled from
// low/high nibble commands. Responses appear on host_out.
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
  localparam CMD_ADDR_0      = 4'h1;  // address[3:0]
  localparam CMD_ADDR_1      = 4'h2;  // address[7:4]
  localparam CMD_ADDR_2      = 4'h3;  // address[9:8]
  localparam CMD_PROG_LO     = 4'h4;  // stage program nibble
  localparam CMD_PROG_HI     = 4'h5;  // stage nibble, write SRAM, address++
  localparam CMD_TX_LO       = 4'h6;  // stage TX nibble
  localparam CMD_TX_HI       = 4'h7;  // stage nibble, push TX FIFO
  localparam CMD_CONTROL     = 4'h8;  // [0] start, [1] stop
  localparam CMD_RX_POP      = 4'h9;
  localparam CMD_STATUS      = 4'ha;
  localparam CMD_READ        = 4'hb;  // read SRAM at address
  localparam CMD_LEVELS      = 4'hc;
  localparam CMD_RX_PEEK     = 4'hd;

  reg [7:0] last_command;
  reg [9:0] address_register;
  reg [9:0] access_address_register;
  reg [7:0] program_data_register;
  reg [7:0] tx_data_register;
  reg [7:0] output_register;
  reg engine_enable_register;
  reg program_write_register;
  reg tx_push_register;
  reg rx_pop_register;
  reg read_bypass;

  wire command_valid = host_in != 8'h00 && host_in != last_command;
  wire [3:0] command = host_in[7:4];
  wire [3:0] payload = host_in[3:0];
  // Command B reads the SRAM in its own cycle, so the byte is on the macro
  // output when the host samples the response. A same-cycle write wins.
  wire read_request = command_valid && command == CMD_READ &&
                      !engine_enable_register && !program_write_register;

  // Bypass the SRAM output to the pins for the cycle after a read, then hold
  // it in the register, so a read answers with the same latency as status.
  assign host_out = read_bypass ? program_read_data : output_register;
  assign engine_enable = engine_enable_register;
  assign program_enable = program_write_register | read_request;
  assign program_write = program_write_register;
  assign program_read = read_request;
  assign program_address = read_request ? address_register :
                                          access_address_register;
  assign program_write_data = program_data_register;
  assign program_write_mask = 8'hff;
  assign tx_push = tx_push_register;
  assign tx_push_data = tx_data_register;
  assign rx_pop = rx_pop_register;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_command <= 8'h00;
      address_register <= 10'b0;
      access_address_register <= 10'b0;
      program_data_register <= 8'b0;
      tx_data_register <= 8'b0;
      output_register <= 8'b0;
      engine_enable_register <= 1'b0;
      program_write_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;
      read_bypass <= 1'b0;
    end else begin
      program_write_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;

      if (engine_halted)
        engine_enable_register <= 1'b0;

      read_bypass <= read_request;
      if (read_bypass)
        output_register <= program_read_data;

      if (host_in == 8'h00)
        last_command <= 8'h00;
      else if (command_valid) begin
        last_command <= host_in;
        case (command)
          CMD_ADDR_0: address_register[3:0] <= payload;
          CMD_ADDR_1: address_register[7:4] <= payload;
          CMD_ADDR_2: address_register[9:8] <= payload[1:0];
          CMD_PROG_LO: program_data_register[3:0] <= payload;
          CMD_PROG_HI: begin
            program_data_register[7:4] <= payload;
            if (!engine_enable_register) begin
              access_address_register <= address_register;
              program_write_register <= 1'b1;
              address_register <= address_register + 1'b1;
            end
          end
          CMD_TX_LO: tx_data_register[3:0] <= payload;
          CMD_TX_HI: begin
            tx_data_register[7:4] <= payload;
            if (!tx_full)
              tx_push_register <= 1'b1;
          end
          CMD_CONTROL: begin
            if (payload[0])
              engine_enable_register <= 1'b1;
            if (payload[1])
              engine_enable_register <= 1'b0;
          end
          CMD_RX_POP: begin
            if (!rx_empty) begin
              output_register <= rx_pop_data;
              rx_pop_register <= 1'b1;
            end
          end
          CMD_STATUS: output_register <= {
              engine_enable_register, engine_halted, tx_full, rx_empty, 4'b0
          };
          CMD_LEVELS: output_register <= {
              tx_full, rx_empty, tx_level, rx_level
          };
          CMD_RX_PEEK: begin
            if (!rx_empty)
              output_register <= rx_pop_data;
          end
          // CMD_READ is handled by read_request above.
          default: begin end
        endcase
      end
    end
  end
endmodule

`default_nettype wire
