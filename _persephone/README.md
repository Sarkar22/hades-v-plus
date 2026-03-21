# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 21.03.2026 16:01  
**Test Deadline:** 01.06.2026 00:00  
### Tested Commit Information
**Date:** 21.03.2026 11:01  
**Hash:** cdfa52b  
**Message:** decode_stage: remove status_forwards_in==VALID guard from hazard detection  
**Committer Email:** esarkar@RF-LT05.eng.uwaterloo.ca  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   8.00 /  8  


</details>


# Module Under Test:  Decode Stage  
<details><summary>Details for the  Decode Stage</summary>

**Points:**   3.94 /  4  

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
## STATUS_IN not VALID  
  
Test input: BEQ with status_backwards_in = READY and status_forwards_in = FETCH_FAULT  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| program_counter_reg_out | 0x00040004 | 0x00040008 | 
| status_forwards_out | 1 | 3 | 
</details>


# Module Under Test:  Register File  
<details><summary>Details for the  Register File</summary>

**Points:**   4.00 /  4  


</details>

