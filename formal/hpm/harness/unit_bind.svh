// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// unit_bind.svh -- the instances of the event block and the counter unit in harness/unit_top.sv.
//
// This is the only file of formal/hpm that names the ports of rtl/hpm_events.sv and rtl/hpm.sv.
// It connects them as rtl/cpu.sv and rtl/writeback_stage.sv connect them, with the harness's
// free signals in place of the CPU's:
//   hpm_events  the raw inputs (backward status d/e/m/wb, fetch ack/err, the operations of the
//               instructions in Execute and Memory, Decode's load-use hazard, the data port's
//               cyc, pending flag and address, the memory-system vector); out: the class-B1
//               events and the first stage of the class-B2 pipeline events, as one struct
//               (hpm_pkg::late_t, every field indexed by event code);
//   hpm         clk, rst, the class-A events (ev_a, bit c = code c, codes 1-20), the struct of
//               hpm_events, the six trap events of Writeback (trap_raw, bit k = code 21 + k),
//               the CSR address, write strobe and write value, the present mask; out: the read
//               value and the inhibit bits of mcycle, minstret and counters 10-13.
// The counter unit's instance must be named u_hpm: the properties read its state through the
// observer props/observe_hpm.svh, under u_hpm.f_obs_*.
// ---------------------------------------------------------------------------------------------
    hpm_pkg::late_t f_bind_late;

    hpm_events u_events (
        .clk             (clk),
        .rst             (rst),
        .status_d        (st_d),
        .status_e        (st_e),
        .status_m        (st_m),
        .status_wb       (st_wb),
        .fetch_ack       (fetch_ack),
        .fetch_err       (fetch_err),
        .op_d            (inst_d.op),
        .op_e            (inst_e.op),
        .load_use_hazard (load_use_hazard),
        .mem_cyc         (mem_cyc),
        .mem_pending     (mem_pending),
        .mem_adr         (mem_adr),
        .ext             (hpm_ext),
        .late            (f_bind_late)
    );

    hpm u_hpm (
        .clk             (clk),
        .rst             (rst),
        .ev_a            (ev_a[20:1]),
        .trap_raw        (trap_raw),
        .late            (f_bind_late),
        .hpm_ext_present (hpm_ext_present),
        .csr_addr        (csr_addr),
        .csr_we          (csr_we),
        .csr_wdata       (csr_wdata),
        .rdata           (rdata),
        .inh_cy          (inh_cy),
        .inh_ir          (inh_ir),
        .inh_bp          (inh_bp)
    );
