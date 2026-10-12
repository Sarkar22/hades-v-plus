// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// env_memory.svh -- the memory behind the single port, made legal by construction. Included
// inside a harness module with the interface mbus (the memory side of the port), the free inputs
// in_m_ans, in_m_err, in_m_dat and the tracked address and word of env_common.svh.
//
// - The memory answers (ack or err) a transfer only in a cycle in which it is presented, after 0
//   to F_MAX_WAIT wait cycles of it (when it answers within that bound is free); never in a cycle
//   with rst = 1, so never to a transfer that a reset dropped. A transfer is the request
//   (address, we, sel, write data) presented in consecutive cycles without an answer; an answer
//   ends it, and a request presented after an answer is a new transfer.
// - Reads return the tracked word at the tracked address and free values elsewhere.
// - A write answered at the tracked address updates the tracked word by its sel lanes.
// - err only outside the window, and never together with ack.
// ---------------------------------------------------------------------------------------------
    wire         m_req = mbus.cyc && mbus.stb;
    logic        m_q_open;                  // the previous cycle presented an unanswered transfer
    logic [1:0]  m_q_wait;
    logic        m_q_we;
    logic [3:0]  m_q_sel;
    logic [31:0] m_q_adr, m_q_dat;
    wire         m_same = m_q_open && m_req && mbus.adr == m_q_adr && mbus.we == m_q_we &&
                          mbus.sel == m_q_sel && mbus.dat_mosi == m_q_dat;
    wire  [1:0]  m_wait = m_same ? m_q_wait + 2'd1 : 2'd0;   // wait cycles spent before this one
    wire         m_ans  = m_req && !rst && (in_m_ans || m_wait == 2'(F_MAX_WAIT));
    assign mbus.err      = m_ans && !f_inwin(mbus.adr) && in_m_err;
    assign mbus.ack      = m_ans && !mbus.err;
    assign mbus.dat_miso = (!mbus.we && mbus.adr == f_adr) ? f_word : in_m_dat;
    always_ff @(posedge clk) begin
        m_q_open <= m_req && !m_ans && !rst;
        m_q_wait <= m_wait;
        m_q_we   <= mbus.we;
        m_q_sel  <= mbus.sel;
        m_q_adr  <= mbus.adr;
        m_q_dat  <= mbus.dat_mosi;
        if (mbus.ack && mbus.we && mbus.adr == f_adr)
            f_word <= f_merge(f_word, mbus.dat_mosi, mbus.sel);
    end
