`default_nettype none

// PX8 controller against an independently written ISA reference model. The
// program is a symbolic 16-byte SRAM image (any instruction sequence,
// addresses alias modulo 16), so every opcode, prefix chain, branch and
// stall is explored. Each cycle the model's state predicts the fetch
// address, every side-effect output, and when the instruction retires
// under arbitrary event/FIFO handshakes.
module px8_controller_properties (input wire clk);   // one solver step = one clock cycle
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;

  (* anyconst *) reg [127:0] rom;
  (* anyseq *) reg        enable;
  (* anyseq *) reg [15:0] rd_data;
  (* anyseq *) reg        event_ready;
  (* anyseq *) reg        tx_grant_any;
  (* anyseq *) reg [7:0]  tx_data;
  (* anyseq *) reg        tx_space;
  (* anyseq *) reg        rx_grant_any;

  wire [9:0]  instruction_address;
  wire        instruction_read;
  wire        cfg_we, event_consume, clear_events, pin_we, pin_value, channel;
  wire        tx_request, tx_push, rx_request, halted;
  wire [7:0]  cfg_addr, rx_data;
  wire [15:0] cfg_data;
  wire [3:0]  rd_addr;
  wire [5:0]  event_index;
  wire [1:0]  fire;
  wire [2:0]  pin_index;
  wire tx_grant = tx_grant_any && tx_request;
  wire rx_grant = rx_grant_any && rx_request;

  function automatic [7:0] rom_at(input [9:0] a);
    rom_at = rom[{a[3:0], 3'b000} +: 8];
  endfunction

  // Synchronous SRAM: data for a read appears the next cycle.
  reg [7:0] instruction_data = 8'd0;
  always @(posedge clk)
    if (instruction_read) instruction_data <= rom_at(instruction_address);

  px8_controller dut (
      .clk(clk), .rst_n(rst_n), .enable(enable),
      .instruction_address(instruction_address),
      .instruction_read(instruction_read),
      .instruction_data(instruction_data),
      .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
      .rd_addr(rd_addr), .rd_data(rd_data),
      .event_ready(event_ready), .event_consume(event_consume),
      .event_index(event_index), .clear_events(clear_events),
      .fire(fire), .pin_we(pin_we), .pin_index(pin_index),
      .pin_value(pin_value), .channel(channel),
      .tx_request(tx_request), .tx_grant(tx_grant), .tx_data(tx_data),
      .tx_push(tx_push), .tx_space(tx_space),
      .rx_request(rx_request), .rx_grant(rx_grant), .rx_data(rx_data),
      .halted(halted)
  );

  // ---------------------------------------------------- reference model
  localparam M_FETCH = 2'd0, M_EXEC = 2'd1, M_LOAD = 2'd2, M_HALT = 2'd3;
  reg [1:0]  m_state = M_FETCH;
  reg [9:0]  m_pc = 10'd0;
  reg [15:0] m_a = 16'd0, m_c = 16'd0, m_o = 16'd0;   // O as a full word
  reg [15:0] m_waited = 16'd0;                        // EXEC cycles so far

  wire [7:0]  ins  = rom_at(m_pc);
  wire [3:0]  op   = ins[7:4];
  wire [3:0]  n    = ins[3:0];
  wire [15:0] opnd = m_o | {12'd0, n};
  wire        opr  = op == 4'he;
  wire [3:0]  sub  = opnd[3:0];
  wire        exec = enable && m_state == M_EXEC;

  reg m_retire;
  always @(*) begin
    case (op)
      4'ha:    m_retire = event_ready;
      4'hd:    m_retire = m_waited == opnd;
      4'he:    m_retire = sub == 4'd2 ? tx_grant :
                          sub == 4'd3 ? rx_grant :
                          sub == 4'd7 ? tx_space : 1'b1;
      default: m_retire = 1'b1;
    endcase
  end

  always @(posedge clk) begin
    if (reset_cycles != 2'd3)
      reset_cycles <= reset_cycles + 1'b1;
    if (!rst_n || !enable) begin
      m_state <= M_FETCH; m_pc <= 10'd0;
      m_a <= 16'd0; m_c <= 16'd0; m_o <= 16'd0; m_waited <= 16'd0;
    end else begin
      case (m_state)
        M_FETCH: begin m_state <= M_EXEC; m_waited <= 16'd0; end
        M_EXEC: if (!m_retire) m_waited <= m_waited + 16'd1; else begin
          m_state <= M_FETCH;
          m_pc <= m_pc + 10'd1;
          m_o <= 16'd0;
          case (op)
            4'h0: m_o <= opnd << 4;
            4'h1: m_a <= opnd;
            4'h2: m_a <= m_a + opnd;
            4'h3: m_a <= m_a ^ opnd;
            4'h4: m_pc <= opnd[9:0];
            4'h5: if (m_a == 16'd0) m_pc <= opnd[9:0];
            4'h6: begin
              m_c <= m_c - 16'd1;
              if (m_c != 16'd1) m_pc <= opnd[9:0];
            end
            4'h7: m_c <= opnd;
            4'h9: m_a <= rd_data;
            4'hf: m_a <= m_a & opnd;
            4'he: case (sub)
              4'd1: m_state <= M_HALT;
              4'd2: m_a <= {8'd0, tx_data};
              4'd5: m_a <= m_c;
              4'd6: m_c <= m_a;
              4'd8: m_state <= M_LOAD;
              default: begin end
            endcase
            default: begin end
          endcase
        end
        M_LOAD: begin
          m_a <= {8'd0, rom_at(m_c[9:0])};
          m_c <= m_c + 16'd1;
          m_state <= M_FETCH;
        end
        default: begin end
      endcase
    end
  end

  // ------------------------------------------------------- assertions
  reg past_valid = 1'b0;
  always @(posedge clk) past_valid <= rst_n;

  always @(*) begin
    if (rst_n && past_valid && enable) begin
      assert(halted == (m_state == M_HALT));
      assert(instruction_read == (m_state == M_FETCH || (exec && opr && sub == 4'd8)));
      if (m_state == M_FETCH) assert(instruction_address == m_pc);
      if (exec && opr && sub == 4'd8) assert(instruction_address == m_c[9:0]);
      assert(cfg_we == (exec && op == 4'h8));
      if (cfg_we) assert(cfg_addr == opnd[7:0] && cfg_data == m_a);
      if (exec && op == 4'h9) assert(rd_addr == opnd[3:0]);
      assert(event_consume == (exec && op == 4'ha && event_ready));
      if (exec && op == 4'ha) assert(event_index == opnd[5:0]);
      assert(clear_events == (exec && opr && sub == 4'd4));
      assert(fire == ((exec && op == 4'hb) ? (opnd[0] ? 2'b10 : 2'b01) : 2'b00));
      assert(pin_we == (exec && op == 4'hc));
      if (pin_we) assert(pin_index == n[2:0] && pin_value == n[3]);
      assert(tx_request == (exec && opr && sub == 4'd2));
      assert(rx_request == (exec && opr && sub == 4'd3));
      assert(tx_push == (exec && opr && sub == 4'd7 && tx_space));
      if (rx_request) assert(rx_data == m_a[7:0]);
      if (tx_push) assert(rx_data == m_a[7:0]);
      if (tx_request || rx_request || tx_push) assert(channel == opnd[4]);
    end
  end

  always @(*) begin
    if (rst_n && past_valid && enable) begin
      cover(halted && m_a == 16'h0123);            // a prefixed constant
      cover(cfg_we && cfg_addr == 8'h31);          // a prefixed config write
      cover(m_state == M_LOAD && m_c == 16'd5);    // LDM from data
      cover(exec && op == 4'h6 && m_c == 16'd2 && m_pc == 10'd3);  // a DJNZ loop
    end
  end
endmodule

`default_nettype wire
