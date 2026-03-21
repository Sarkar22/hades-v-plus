# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 21.03.2026 20:01  
**Test Deadline:** 01.06.2026 00:00  
### Tested Commit Information
**Date:** 21.03.2026 15:17  
**Hash:** 4ee6165  
**Message:** fix decode_stage: STALL hold + remove csr_use_hazard exe override  
**Committer Email:** esarkar@RF-LT05.eng.uwaterloo.ca  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   8.00 /  8  


</details>


# Module Under Test:  Decode Stage  
<details><summary>Details for the  Decode Stage</summary>

**Points:**   3.93 /  4  

## FORWARDING  
### forward newest result (more stages same rd - only newest valid)  
  
Test input: JALR with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| rs1_data_reg_out | 0x88888888 | 0x11111111 | 
| program_counter_reg_out | 0x00040010 | 0x00040014 | 
| instruction_reg_out.op | 18 | 3 | 
| instruction_reg_out.rd_address | 0 | 8 | 
| instruction_reg_out.rs1_address | 0 | 14 | 
| instruction_reg_out.immediate | 0x00000000 | 0xfffff876 | 
| status_forwards_out | 1 | 0 | 
  
Test input: LHU with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| rs1_data_reg_out | 0x22222222 | 0x33333333 | 
| program_counter_reg_out | 0x00040018 | 0x0004001c | 
| instruction_reg_out.op | 18 | 14 | 
| instruction_reg_out.rd_address | 0 | 7 | 
| instruction_reg_out.rs1_address | 0 | 16 | 
| instruction_reg_out.immediate | 0x00000000 | 0xfffff876 | 
| status_forwards_out | 1 | 0 | 
## FORWARDING NOT VALID => insert BUBBLE  
  
Test input: SW with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 1 | 
| status_forwards_out | 0 | 1 | 
  
Test input: SLT with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 1 | 
| status_forwards_out | 0 | 1 | 
### now status_backwards_in = READY, but forwarding.data_valid = 0 => insert BUBBLE  
  
Test input: SLT with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 1 | 
| status_forwards_out | 0 | 1 | 
### now status_backwards_in = READY and forwarding.data_valid = 0 => insert BUBBLE  
  
Test input: SLT with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 1 | 
| status_forwards_out | 0 | 1 | 
</details>


# Module Under Test:  Register File  
<details><summary>Details for the  Register File</summary>

**Points:**   4.00 /  4  


</details>

