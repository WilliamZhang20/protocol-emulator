`default_nettype none

// Nibble-command host interface. The demo board's microcontroller drives
// host_in asynchronously, so the pins pass a two-flop synchronizer and a
// byte counts only once it has been stable for two cycles: a command (or
// the 8'h00 that must separate commands) must be held for at least two
// clocks. A byte caught mid-change can therefore never act. Program and
// payload bytes are assembled from low/high nibble commands so all eight
// pins remain available as host data.
//
// A command byte is {command[3:0], payload[3:0]}. Commands do one of two
// things: change interface state (address, data, strobes, enable,
// channel), or put a response on host_out. host_out is a register that
// holds the last response until another response command replaces it.
//
// State commands (host_out keeps its last response):
//   1 / 2 / 3  address[3:0] / [7:4] / [9:8] = payload
//   4 / 6      low nibble = payload (for 5 / 7)
//   5          SRAM[address] = {payload, low nibble}; address += 1
//              (stopped only)
//   7 / F      TX push {payload, low nibble} (dropped if full); F tags the
//              byte eop, the last byte of a packet
//   8          payload[0] start, payload[1] stop
//   E          FIFO channel = payload[0]
// Response commands (the answer goes to host_out):
//   9          pop RX (if not empty)
//   A          status {enable, halted, tx_full, rx_empty, 2'b0, eop, err};
//              eop/err are the tags of the RX byte that 9 would pop next
//              (0 when the RX FIFO is empty)
//   B          SRAM[address], two cycles later (stopped only)
//   C          levels {tx_full, rx_empty, tx_level, rx_level}
//   D          peek RX without popping (if not empty)
//
// TX, RX, status and level commands use the channel selected by E (one
// FIFO channel per shifter).
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
    output wire       channel,           // FIFO channel for TX/RX commands
    output wire       tx_push,
    output wire [9:0] tx_push_data,      // {err, eop, byte}
    input  wire       tx_full,
    input  wire [2:0] tx_level,
    output wire       rx_pop,
    input  wire [9:0] rx_pop_data,       // {err, eop, byte}
    input  wire       rx_empty,
    input  wire [2:0] rx_level,
    input  wire       engine_halted
);
  (* async_reg = "true" *) reg [7:0] host_meta;
  (* async_reg = "true" *) reg [7:0] host_sync;
  reg [7:0] host_prev;
  reg       seen;              // a command was accepted since the last 8'h00
  reg [9:0] address_register;
  reg [3:0] low_nibble;
  reg [7:0] data_register;
  reg       eop_register;      // the TX byte being pushed ends a packet
  reg [7:0] output_register;
  reg engine_enable_register;
  reg program_write_register;
  reg program_read_register;
  reg tx_push_register;
  reg rx_pop_register;
  reg read_capture;            // SRAM data is valid the cycle after a read
  reg channel_register;

  localparam CMD_ADDR_0   = 4'h1, CMD_ADDR_1  = 4'h2, CMD_ADDR_2 = 4'h3;
  localparam CMD_PROG_LO  = 4'h4, CMD_PROG_HI = 4'h5;
  localparam CMD_TX_LO    = 4'h6, CMD_TX_HI   = 4'h7;
  localparam CMD_ENGINE   = 4'h8, CMD_RX_POP  = 4'h9, CMD_STATUS = 4'ha;
  localparam CMD_SRAM_READ = 4'hb, CMD_LEVELS = 4'hc, CMD_RX_PEEK = 4'hd;
  localparam CMD_CHANNEL  = 4'he, CMD_TX_EOP = 4'hf;

  wire stable = host_sync == host_prev;
  wire command_valid = stable && host_sync != 8'h00 && !seen;
  wire [3:0] command = host_sync[7:4];
  wire [3:0] payload = host_sync[3:0];

  assign host_out = output_register;
  assign engine_enable = engine_enable_register;
  assign program_enable = program_write_register | program_read_register;
  assign program_write = program_write_register;
  assign program_read = program_read_register;
  assign program_address = address_register;
  assign program_write_data = data_register;
  assign program_write_mask = 8'hff;
  assign channel = channel_register;
  assign tx_push = tx_push_register;
  assign tx_push_data = {1'b0, eop_register, data_register};
  assign rx_pop = rx_pop_register;

  always @(posedge clk) begin
    if (!rst_n) begin
      host_meta <= 8'h00;
      host_sync <= 8'h00;
      host_prev <= 8'h00;
      seen <= 1'b0;
      address_register <= 10'b0;
      low_nibble <= 4'b0;
      data_register <= 8'b0;
      eop_register <= 1'b0;
      output_register <= 8'b0;
      engine_enable_register <= 1'b0;
      program_write_register <= 1'b0;
      program_read_register <= 1'b0;
      tx_push_register <= 1'b0;
      rx_pop_register <= 1'b0;
      read_capture <= 1'b0;
      channel_register <= 1'b0;
    end else begin
      host_meta <= host_in;
      host_sync <= host_meta;
      host_prev <= host_sync;
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

      if (stable && host_sync == 8'h00)
        seen <= 1'b0;
      else if (command_valid) begin
        seen <= 1'b1;
        case (command)
          // ---- state commands: host_out keeps its last response
          CMD_ADDR_0: address_register[3:0] <= payload;
          CMD_ADDR_1: address_register[7:4] <= payload;
          CMD_ADDR_2: address_register[9:8] <= payload[1:0];
          // The low nibble waits here until its high-nibble command
          // commits the whole byte.
          CMD_PROG_LO, CMD_TX_LO: low_nibble <= payload;
          // Program write: only while stopped, so the engine owns the SRAM
          // whenever it runs.
          CMD_PROG_HI: begin
            data_register <= {payload, low_nibble};
            if (!engine_enable_register)
              program_write_register <= 1'b1;
          end
          // TX push: a byte sent to a full FIFO is dropped. F also tags it
          // as the last byte of a packet.
          CMD_TX_HI, CMD_TX_EOP: begin
            data_register <= {payload, low_nibble};
            eop_register  <= command == CMD_TX_EOP;
            if (!tx_full)
              tx_push_register <= 1'b1;
          end
          CMD_ENGINE: begin
            if (payload[0])
              engine_enable_register <= 1'b1;
            if (payload[1])
              engine_enable_register <= 1'b0;
          end
          CMD_CHANNEL: channel_register <= payload[0];

          // ---- response commands: the answer goes to host_out
          // Pop: the byte leaves the FIFO. On an empty FIFO nothing is
          // popped and host_out keeps its last value (check status first).
          CMD_RX_POP: begin
            if (!rx_empty) begin
              output_register <= rx_pop_data[7:0];
              rx_pop_register <= 1'b1;
            end
          end
          // The head byte's tags only exist when there is a head byte
          // (FIFO memory is not reset).
          CMD_STATUS: output_register <= {
              engine_enable_register, engine_halted, tx_full, rx_empty, 2'b0,
              !rx_empty && rx_pop_data[8], !rx_empty && rx_pop_data[9]
          };
          // SRAM readback (stopped only): the strobe goes out now, and the
          // byte reaches host_out through read_capture above.
          CMD_SRAM_READ: begin
            if (!engine_enable_register)
              program_read_register <= 1'b1;
          end
          // Streaming aids: FIFO levels for polled drivers, and an RX peek
          // that leaves the byte in the FIFO.
          CMD_LEVELS: output_register <= {
              tx_full, rx_empty, tx_level, rx_level
          };
          CMD_RX_PEEK: begin
            if (!rx_empty)
              output_register <= rx_pop_data[7:0];
          end
          // 0 never reaches here: it separates commands.
          default: begin end
        endcase
      end
    end
  end
endmodule

`default_nettype wire
