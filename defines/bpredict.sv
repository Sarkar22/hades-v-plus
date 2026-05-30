/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: bpredict.sv
 */

package bpredict;
    typedef struct packed {
        logic       valid;            // high when this is a real aligned branch prediction
        logic       predicted_taken;  // predictor's guess
        logic       was_taken;        // actual outcome (filled in by Execute stage)
        logic [4:0] index;            // counter table index (for 2-bit array update)
    } bp_data_t;
endpackage
