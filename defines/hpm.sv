// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// hpm.sv -- the package hpm_pkg of the hardware performance counters (a package named hpm
// would clash with the counter unit, module hpm in rtl/hpm.sv).
//
// Hardware performance counters: mhpmcounter3-9 (with their high halves),
// mhpmevent3-9 and mcountinhibit (docs/EXTENSIONS.md). This package holds the
// event codes, the bit order of the memory-system event vector, the build
// parameters and the inhibit register's address. defines/csr.sv is left as it
// is: the counter unit (rtl/hpm.sv) decodes its addresses numerically.
//
// Build options (Verilator +define+..., all optional):
//   HADES_HPM_COUNTERS=<0..7>  programmable counters 3 .. 2+N (default 7)
//   HADES_HPM_WIDTH=<32..64>   their width in bits (default 48); higher bits read 0
//   HADES_HPM_PRESET=<A..I>    simulation only: the selectors of counters 3-9
//                              reset to a preset set of seven event codes
//                              (PRESET_CODES below) instead of 0

/*verilator lint_off UNUSED*/
/*verilator lint_off DECLFILENAME*/

`ifndef HADES_HPM_COUNTERS
`define HADES_HPM_COUNTERS 7
`endif

`ifndef HADES_HPM_WIDTH
`define HADES_HPM_WIDTH 48
`endif

package hpm_pkg;
    // --------------------------------------------------------------------------------------------
    // |                                     Build parameters                                     |
    // --------------------------------------------------------------------------------------------
    localparam int COUNTERS = `HADES_HPM_COUNTERS;  // N: counters 3 .. 2+N exist
    localparam int WIDTH    = `HADES_HPM_WIDTH;     // W: bits per counter

    // The inhibit register. Every other address of the unit is numeric:
    // mhpmevent3-9 0x323-0x329, mhpmcounter3-9 0xB03-0xB09, their high halves
    // 0xB83-0xB89, and the read-only selectors mhpmevent11-13 0x32B-0x32D.
    localparam bit [11:0] MCOUNTINHIBIT = 12'h320;

    // The bits of mcountinhibit that can be written: CY (0), IR (2), the
    // programmable counters 3 .. 2+N, and the predictor's counters 10-13.
    // TM (1) is read-only 0. 0x0000_3FFD with n = 7.
    function automatic bit [31:0] inhibit_mask(int n);
        return 32'h0000_3C05 | (((32'd1 << n) - 32'd1) << 3);
    endfunction

    // --------------------------------------------------------------------------------------------
    // |                                       Event codes                                        |
    // --------------------------------------------------------------------------------------------
    // One 8-bit code per counter, held in mhpmevent[7:0]. Codes are append-only:
    // a published code is never renumbered or reused.
    //   0          no event
    //   1-31       architectural events
    //   32-127     pipeline events
    //   128-159    memory-system signals, code 128 + k = bit k of the event vector
    //   160-191    combined memory-system codes
    //   192-255    reserved
    //
    // Counting classes (when an event reaches the counter):
    //   A   at the end of the cycle its instruction is in Writeback (like minstret)
    //   B1  one cycle after the condition
    //   B2  two cycles after the condition

    // Architectural (1-31)
    localparam bit [7:0] EV_NONE          = 8'd0;
    localparam bit [7:0] EV_CYCLE         = 8'd1;   // A
    localparam bit [7:0] EV_INSTRET       = 8'd2;   // A
    localparam bit [7:0] EV_LOAD          = 8'd3;   // A
    localparam bit [7:0] EV_STORE         = 8'd4;   // A
    localparam bit [7:0] EV_BRANCH        = 8'd5;   // A
    localparam bit [7:0] EV_BRANCH_TAKEN  = 8'd6;   // A
    localparam bit [7:0] EV_JUMP          = 8'd7;   // A
    localparam bit [7:0] EV_MUL           = 8'd8;   // A
    localparam bit [7:0] EV_DIV           = 8'd9;   // A
    localparam bit [7:0] EV_CSR           = 8'd10;  // A
    localparam bit [7:0] EV_BITMANIP      = 8'd11;  // A
    localparam bit [7:0] EV_CRYPTO        = 8'd12;  // A
    localparam bit [7:0] EV_MRET          = 8'd13;  // A
    localparam bit [7:0] EV_FENCE_I       = 8'd14;  // A
    localparam bit [7:0] EV_REPLAY        = 8'd15;  // A
    localparam bit [7:0] EV_BR_MISPREDICT = 8'd16;  // A (predictor record, at the branch's retirement)
    localparam bit [7:0] EV_BP_NN         = 8'd17;  // A
    localparam bit [7:0] EV_BP_NT         = 8'd18;  // A
    localparam bit [7:0] EV_BP_TN         = 8'd19;  // A
    localparam bit [7:0] EV_BP_TT         = 8'd20;  // A
    localparam bit [7:0] EV_EXCEPTION     = 8'd21;  // B2
    localparam bit [7:0] EV_EXC_ECALL     = 8'd22;  // B2
    localparam bit [7:0] EV_EXC_OTHER     = 8'd23;  // B2
    localparam bit [7:0] EV_INTERRUPT     = 8'd24;  // B2
    localparam bit [7:0] EV_INT_TIMER     = 8'd25;  // B2
    localparam bit [7:0] EV_INT_EXT       = 8'd26;  // B2

    // Pipeline (32-127). 32-37 divide every cycle into exactly one class.
    localparam bit [7:0] EV_FETCH_WAIT      = 8'd32;  // B2
    localparam bit [7:0] EV_FRONT_OK        = 8'd33;  // B2
    localparam bit [7:0] EV_HAZARD          = 8'd34;  // B2
    localparam bit [7:0] EV_MSTALL_ANY      = 8'd35;  // B2
    localparam bit [7:0] EV_MEMWAIT_ANY     = 8'd36;  // B2
    localparam bit [7:0] EV_REDIRECT_ANY    = 8'd37;  // B2
    localparam bit [7:0] EV_HAZARD_LOAD     = 8'd38;  // B2
    localparam bit [7:0] EV_MSTALL_MUL      = 8'd39;  // B2
    localparam bit [7:0] EV_MSTALL_DIV      = 8'd40;  // B2
    localparam bit [7:0] EV_MEMWAIT_LOAD    = 8'd41;  // B2
    localparam bit [7:0] EV_MEMWAIT_STORE   = 8'd42;  // B2
    localparam bit [7:0] EV_MEMWAIT_IO      = 8'd43;  // B2
    localparam bit [7:0] EV_REDIRECT_BRANCH = 8'd44;  // B2
    localparam bit [7:0] EV_REDIRECT_JUMP   = 8'd45;  // B2
    localparam bit [7:0] EV_REDIRECT_WB     = 8'd46;  // B2
    localparam bit [7:0] EV_FETCH_DELIVER   = 8'd47;  // B1
    localparam bit [7:0] EV_FETCH_DISCARD   = 8'd48;  // B1
    localparam bit [7:0] EV_IO_ACCESS       = 8'd49;  // B1

    // Memory system (128-191), all B1. Codes 128-139 are bits 0-11 of the event
    // vector (EXT_* below); they and the combined codes are legal only in a
    // build whose configuration drives the bit (the present mask).
    localparam bit [7:0] EV_IC_LOOKUP_HIT  = 8'd128;
    localparam bit [7:0] EV_IC_MISS        = 8'd129;
    localparam bit [7:0] EV_IC_BEAT        = 8'd130;
    localparam bit [7:0] EV_IC_FILL        = 8'd131;
    localparam bit [7:0] EV_IC_ABANDON     = 8'd132;
    localparam bit [7:0] EV_IC_SNOOP_INVAL = 8'd133;
    localparam bit [7:0] EV_PORT_WAIT_I    = 8'd134;
    localparam bit [7:0] EV_PORT_WAIT_D    = 8'd135;
    localparam bit [7:0] EV_PORT_GRANT_I   = 8'd136;
    localparam bit [7:0] EV_PORT_GRANT_D   = 8'd137;
    localparam bit [7:0] EV_PORT_LOAD      = 8'd138;
    localparam bit [7:0] EV_PORT_STORE     = 8'd139;
    localparam bit [7:0] EV_IC_HIT_USED    = 8'd160;  // IC_LOOKUP_HIT and Decode takes the word
    localparam bit [7:0] EV_IC_MISS_JUMP   = 8'd161;  // IC_MISS while Fetch is redirected

    // --------------------------------------------------------------------------------------------
    // |                        Memory-system event vector (bit order)                           |
    // --------------------------------------------------------------------------------------------
    // Bit k of the vector (rtl/mcu.sv: hpm_ext) is event code 128 + k. A new
    // event takes the next free bit; the order never changes. Bits 12-31 are
    // reserved for later memory-system events.
    localparam int EXT_IC_LOOKUP_HIT  = 0;   // cache_ev_i_hit
    localparam int EXT_IC_MISS        = 1;   // cache_ev_i_miss
    localparam int EXT_IC_BEAT        = 2;   // cache_ev_i_beat
    localparam int EXT_IC_FILL        = 3;   // cache_ev_i_fill
    localparam int EXT_IC_ABANDON     = 4;   // cache_ev_i_abandoned
    localparam int EXT_IC_SNOOP_INVAL = 5;   // cache_ev_i_snoop_inval
    localparam int EXT_PORT_WAIT_I    = 6;   // cache_ev_wait_i
    localparam int EXT_PORT_WAIT_D    = 7;   // cache_ev_wait_d
    localparam int EXT_PORT_GRANT_I   = 8;   // cache_ev_grant_i
    localparam int EXT_PORT_GRANT_D   = 9;   // cache_ev_grant_d
    localparam int EXT_PORT_LOAD      = 10;  // cache_ev_port_load
    localparam int EXT_PORT_STORE     = 11;  // cache_ev_port_store

    // --------------------------------------------------------------------------------------------
    // |                         Events delivered late to the counter unit                        |
    // --------------------------------------------------------------------------------------------
    // Computed by rtl/hpm_events.sv from its registered copies of the raw
    // conditions, so every field is already one cycle late. Each field is
    // indexed by event code (bit 47 of b1 is code 47, ...).
    typedef struct packed {
        logic [161:160] comb;  // B1: IC_HIT_USED, IC_MISS_JUMP
        logic [31:0]    ext;   // B1: codes 128-159, bit k = code 128 + k
        logic [49:47]   b1;    // B1: FETCH_DELIVER, FETCH_DISCARD, IO_ACCESS
        logic [46:32]   b2;    // B2, first stage: the pipeline events 32-46
    } late_t;

    // --------------------------------------------------------------------------------------------
    // |                                    Implemented codes                                     |
    // --------------------------------------------------------------------------------------------
    // The WARL rule of mhpmevent3-9: a written value is kept only if it is a
    // code this build has (value[31:8] == 0 and implemented(value[7:0])),
    // otherwise the selector takes 0, "no event". present is the configuration's
    // present mask of the memory-system vector.
    function automatic logic implemented(input logic [7:0] code, input logic [31:0] present);
        if (code >= 8'd1 && code <= 8'd26)
            return 1'b1;
        else if (code >= 8'd32 && code <= 8'd49)
            return 1'b1;
        else if (code >= 8'd128 && code <= 8'd159)
            return present[code[4:0]];
        else if (code == EV_IC_HIT_USED)
            return present[EXT_IC_LOOKUP_HIT];
        else if (code == EV_IC_MISS_JUMP)
            return present[EXT_IC_MISS];
        else
            return 1'b0;
    endfunction

    function automatic logic legal(input logic [31:0] value, input logic [31:0] present);
        return value[31:8] == 24'b0 && implemented(value[7:0], present);
    endfunction

    // --------------------------------------------------------------------------------------------
    // |                         Simulation-only presets of the selectors                         |
    // --------------------------------------------------------------------------------------------
    // +define+HADES_HPM_PRESET=<A..I>: mhpmevent3-9 reset to the preset's seven
    // codes, element 0 to mhpmevent3. Together the presets cover every code.
    // H and I hold memory-system codes and need an I-cache build: the counter
    // unit stops the simulation at the first clock edge if a preset holds a
    // code that the build lacks. The letters are names of this package so that
    // the define can be given as a plain letter (never import this package with
    // a wildcard).
    typedef bit [6:0][7:0] preset_t;   // element 0 is mhpmevent3's code

    localparam int NO_PRESET = 0;
    localparam int A = 1;  // cycles
    localparam int B = 2;  // mix 1
    localparam int C = 3;  // mix 2
    localparam int D = 4;  // traps
    localparam int E = 5;  // predictor
    localparam int F = 6;  // stalls
    localparam int G = 7;  // fetch
    localparam int H = 8;  // I-cache (I-cache builds only)
    localparam int I = 9;  // memory port (I-cache builds only)

`ifdef HADES_HPM_PRESET
    localparam int PRESET = `HADES_HPM_PRESET;
`else
    localparam int PRESET = NO_PRESET;
`endif

    // The seven codes in counter order: the first for mhpmevent3, the last for mhpmevent9
    function automatic preset_t codes7(input bit [7:0] first, second, third, fourth, fifth, sixth, last);
        return {last, sixth, fifth, fourth, third, second, first};
    endfunction

    function automatic preset_t preset_codes(input int preset);
        case (preset)
            A:       return codes7(8'd32,  8'd33,  8'd34,  8'd35,  8'd36,  8'd37,  8'd16);
            B:       return codes7(8'd2,   8'd3,   8'd4,   8'd5,   8'd7,   8'd8,   8'd9);
            C:       return codes7(8'd1,   8'd6,   8'd10,  8'd11,  8'd12,  8'd13,  8'd14);
            D:       return codes7(8'd15,  8'd21,  8'd22,  8'd23,  8'd24,  8'd25,  8'd26);
            E:       return codes7(8'd17,  8'd18,  8'd19,  8'd20,  8'd44,  8'd45,  8'd46);
            F:       return codes7(8'd38,  8'd39,  8'd40,  8'd41,  8'd42,  8'd43,  8'd49);
            G:       return codes7(8'd47,  8'd48,  8'd32,  8'd33,  8'd1,   8'd2,   8'd16);
            H:       return codes7(8'd160, 8'd128, 8'd129, 8'd130, 8'd131, 8'd132, 8'd161);
            I:       return codes7(8'd133, 8'd134, 8'd135, 8'd136, 8'd137, 8'd138, 8'd139);
            default: return '0;
        endcase
    endfunction

    localparam preset_t PRESET_CODES = preset_codes(PRESET);
endpackage

/*verilator lint_on DECLFILENAME*/
/*verilator lint_on UNUSED*/
