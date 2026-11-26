`default_nettype none

// Lane controller against an independently written ISA reference model.
// The program is a symbolic 8-byte SRAM image (up to four instructions,
// addresses alias modulo 8) at a symbolic base, so every opcode, operand,
// branch, wait and stall is explored. Start, abort, enable, events, levels,
// readback, the stream handshakes and SRAM port stalls are arbitrary. Each
// cycle the model predicts the load address, every side-effect output
// (actions, start pulse, tx word, stream consume/push, configuration write
// and its fence) and done/error.
module lane_controller_properties (input wire clk);
  reg [1:0] reset_cycles = 2'b0;
  wire rst_n = reset_cycles >= 2;
  always @(posedge clk) if (!rst_n) reset_cycles <= reset_cycles + 1'b1;

  (* anyconst *) reg [63:0] rom;
  (* anyconst *) reg [9:0] base;
  (* anyconst *) reg [1:0] last2;
  (* anyconst *) reg [3:0] idle;
  (* anyseq *) reg enable, start, abort, mem_ready, rd_valid, wr_ready, cfg_ok;
  (* anyseq *) reg [7:0] events, levels, rd_data;
  (* anyseq *) reg [255:0] readback;
  wire [5:0] last = {4'b0, last2};

  function automatic [7:0] rom_at(input [9:0] a);
    rom_at = rom[{a[2:0], 3'b000} +: 8];
  endfunction
  // Instruction i of the program (aliases modulo four, like the image).
  wire [15:0] words [0:3];
  genvar gw;
  generate for (gw = 0; gw < 4; gw = gw + 1) begin: wd
    assign words[gw] = {rom_at(base + 10'd2 * gw + 10'd1), rom_at(base + 10'd2 * gw)};
  end endgenerate

  // Synchronous SRAM read port: data the clock after an accepted request.
  wire mem_req, owns_port, resp_pending;
  wire [9:0] mem_addr;
  reg mem_rvalid = 0; reg [7:0] mem_rdata = 0;
  always @(posedge clk) begin
    mem_rvalid <= mem_req && mem_ready;
    if (mem_req && mem_ready) mem_rdata <= rom_at(mem_addr);
  end

  wire [3:0] actions; wire fire, tx_load, rd_consume, rd_want, wr_valid, cfg_we;
  wire [15:0] tx_word, cfg_data, acc; wire [7:0] wr_data, cfg_addr, count;
  wire active, loading, done, error; wire [5:0] pc;
  grid_lane_controller #(.ABITS(2)) dut(clk, rst_n, enable, start, abort, base, last,
    mem_req, mem_ready, mem_addr, mem_rvalid, mem_rdata, owns_port, resp_pending,
    events, levels, readback, idle, actions, fire, tx_word, tx_load,
    rd_valid, rd_data, rd_consume, rd_want, wr_valid, wr_data, wr_ready,
    cfg_we, cfg_addr, cfg_data, cfg_ok, active, loading, done, error, pc, acc, count,
    d_latched, d_act, d_sent, d_got, d_low, d_shift_fire, d_prog);
  wire [7:0] d_latched, d_sent, d_got, d_low; wire [3:0] d_act; wire d_shift_fire; wire [63:0] d_prog;

  // ---------------- reference model ----------------
  localparam IDLE = 2'd0, LOAD = 2'd1, RUN = 2'd2;
  reg [1:0] mode = IDLE;
  reg [7:0] m_sent = 0, m_got = 0;
  reg [5:0] m_pc = 0;
  reg [15:0] m_a = 0, m_tx = 0;
  reg [7:0] m_c = 0, m_seen = 0;
  reg [3:0] m_act = 0;
  reg m_done = 0, m_err = 0, m_fire_next = 0;
  wire [7:0] m_bytes = 8'd2 * ({2'b0, last} + 8'd1);

  wire [15:0] w = words[m_pc[1:0]];
  wire [3:0] o = w[15:12];
  wire [11:0] k = w[11:0];
  wire in_run = mode == RUN;
  wire off_end = m_pc > last;
  wire is_wait = o == 4'h1;
  wire is_sys = o == 4'h0;
  wire is_pull = is_sys && k[3:0] == 4'd5;
  wire is_push = is_sys && k[3:0] == 4'd6;
  wire is_shift = is_sys && k[3:0] == 4'd4;
  wire level_wait = k[3];
  wire ready_wait = level_wait ? levels[k[2:0]] : (m_seen[k[2:0]] | events[k[2:0]]);
  wire is_any = o == 4'hF;
  wire any_bad = k[11:8] != 4'd0 || k[7:0] == 8'd0;
  wire [7:0] any_hit = (m_seen | events) & k[7:0];
  wire blocked = (is_any && !any_bad && any_hit == 8'd0) || (is_wait && !ready_wait) || (is_pull && !rd_valid) || (is_push && !wr_ready);
  wire step = in_run && !off_end && !blocked;
  wire owned = k[11:8] == 4'd0 && k[7:0] >= 8'd112 && k[7:0] <= 8'd116;
  // The fabric's check of the value (cfg_ok) is arbitrary here.
  wire may_write = owned && cfg_ok;
  wire jump_ok = k[11:6] == 6'd0 && k[5:0] <= last;
  wire taken = (o == 4'h9) || (o == 4'hA && m_a == 16'd0) || (o == 4'hB && m_a != 16'd0) ||
               (o == 4'hC && m_c != 8'd1);
  wire is_jump = o >= 4'h9 && o <= 4'hC;
  wire bad = (is_sys && k[3:0] > 4'd8) || (is_any && any_bad) || (o == 4'hE && !may_write) ||
             (is_jump && taken && !jump_ok);
  wire halts = is_sys && (k[3:0] == 4'd1 || k[3:0] == 4'd2);

  // Expected combinational outputs this cycle.
  wire live = rst_n && enable;
  wire e_req = live && mode == LOAD && m_sent != m_bytes;
  wire [9:0] e_addr = base + {2'b0, m_sent};
  wire e_consume = live && in_run && !off_end && is_pull && rd_valid;
  wire e_push = live && in_run && !off_end && is_push;
  wire e_load = live && in_run && !off_end && is_shift;
  wire e_fire = (live && in_run && !off_end && o == 4'h3) || m_fire_next;
  wire e_cfg = live && in_run && !off_end && o == 4'hE && may_write;
  wire [3:0] e_actions = (mode != IDLE) ? m_act : idle;

  always @(*) if (rst_n && enable) begin
    assert (mem_req == e_req);
    if (e_req) assert (mem_addr == e_addr);
    assert (rd_consume == e_consume);
    assert (rd_want == (live && in_run && !off_end && is_pull));
    assert (wr_valid == e_push);
    if (e_push) assert (wr_data == m_a[7:0]);
    assert (tx_load == e_load);
    assert (cfg_we == e_cfg);
    if (e_cfg) assert (cfg_addr == k[7:0] && cfg_data == m_a);
    assert (actions == e_actions);
    assert (active == (mode != IDLE));
    assert (loading == (mode == LOAD));
  end
  // The write fence holds whatever the program does, and a refused value is
  // never written.
  always @(*) if (cfg_we) assert (cfg_addr >= 8'd112 && cfg_addr <= 8'd116 && cfg_ok);
  always @(*) if (rst_n) begin
    assert (fire == e_fire);
    assert (done == m_done);
    if (enable) assert (error == m_err);
    assert (tx_word == m_tx);
  end

  always @(posedge clk) begin
    m_done <= 1'b0;
    m_fire_next <= rst_n && enable && in_run && !off_end && is_shift;
    if (!rst_n || !enable) begin
      mode <= IDLE; m_err <= 1'b0; m_act <= 4'd0; m_seen <= 8'd0;
      if (!rst_n) m_tx <= 16'd0;
    end else begin
      m_seen <= m_seen | events;
      if (mode != IDLE && abort) begin mode <= IDLE; m_done <= 1'b1; m_err <= 1'b1; end
      else if (mode == IDLE && start) begin
        mode <= LOAD; m_sent <= 8'd0; m_got <= 8'd0; m_pc <= 6'd0; m_a <= 16'd0; m_c <= 8'd0;
        m_seen <= 8'd0; m_err <= 1'b0; m_act <= idle;
      end else if (mode == LOAD) begin
        if (mem_req && mem_ready) m_sent <= m_sent + 8'd1;
        if (mem_rvalid) begin
          m_got <= m_got + 8'd1;
          if (m_got == m_bytes - 8'd1) mode <= RUN;
        end
      end else if (in_run && off_end) begin
        mode <= IDLE; m_done <= 1'b1; m_err <= 1'b1;
      end else if (step) begin
        m_pc <= m_pc + 6'd1;
        if (bad) begin mode <= IDLE; m_done <= 1'b1; m_err <= 1'b1; end
        else if (halts) begin mode <= IDLE; m_done <= 1'b1; m_err <= k[3:0] == 4'd2; end
        else begin
          if (is_sys && k[3:0] == 4'd3) m_seen <= events;
          if (is_shift) m_tx <= m_a;
          if (is_pull) m_a <= {8'd0, rd_data};
          if (is_sys && k[3:0] == 4'd7) m_c <= m_a[7:0];
          if (is_sys && k[3:0] == 4'd8) m_a <= {8'd0, m_c};
          if (is_wait && !level_wait) m_seen[k[2:0]] <= 1'b0;
          if (is_any) begin m_a <= {8'd0, any_hit}; m_seen <= (m_seen | events) & ~k[7:0]; end
          if (o == 4'h2) m_act <= k[3:0];
          if (o == 4'h4) m_a <= {4'd0, k};
          if (o == 4'h5) m_a <= readback[{k[3:0], 4'd0} +: 16];
          if (o == 4'h6) m_a <= m_a & {4'd0, k};
          if (o == 4'h7) m_a <= m_a ^ {4'd0, k};
          if (o == 4'h8) m_a <= m_a + {4'd0, k};
          if (o == 4'hC) m_c <= m_c - 8'd1;
          if (o == 4'hD) m_c <= k[7:0];
          if (is_jump && taken) m_pc <= k[5:0];
        end
      end
    end
  end

  // The architectural registers the outputs depend on stay in step.
  always @(*) if (rst_n && enable && in_run) begin
    assert (pc == m_pc); assert (acc == m_a); assert (count == m_c);
  end

  // State correspondence: every register of the controller equals the
  // model's, so k-induction proves the output predictions for all time.
  always @(*) if (rst_n) begin
    assert (active == (mode != IDLE));
    assert (loading == (mode == LOAD));
    assert (mode != 2'd3);
    if (mode != IDLE) assert (!m_err && !m_done);
    assert (d_latched == m_seen);
    assert (d_act == m_act);
    assert (d_shift_fire == m_fire_next);
    assert (tx_word == m_tx);
    assert (resp_pending == mem_rvalid);
    if (mode != IDLE) begin
      assert (pc == m_pc); assert (acc == m_a); assert (count == m_c);
    end
    if (mode == LOAD) begin
      assert (d_sent == m_sent && d_got == m_got);
      assert (m_got < m_bytes && m_sent <= m_bytes);
      assert (m_sent == m_got + {7'd0, mem_rvalid});
      if (mem_rvalid) assert (mem_rdata == rom_at(base + {2'b0, m_got}));
      if (m_got[0]) assert (d_low == rom_at(base + {2'b0, m_got} - 10'd1));
    end
  end
  genvar wi;
  generate for (wi = 0; wi < 4; wi = wi + 1) begin: loaded
    always @(*) if (rst_n && ((mode == RUN && wi <= last) || (mode == LOAD && 2 * wi + 1 < m_got)))
      assert (d_prog[wi*16 +: 16] == words[wi]);
  end endgenerate

  // Reachability: a loaded program runs, waits, pushes, writes, halts both ways.
  always @(*) begin
    cover (rst_n && in_run && o == 4'h1 && !k[3] && ready_wait);
    cover (rst_n && e_push && wr_ready);
    cover (rst_n && e_cfg);
    cover (rst_n && done && !error);
    cover (rst_n && done && error && mode == IDLE);
    cover (rst_n && in_run && is_jump && taken && jump_ok);
    cover (rst_n && in_run && is_any && !any_bad && any_hit != 8'd0 && any_hit != k[7:0]);
  end
endmodule
`default_nettype wire
