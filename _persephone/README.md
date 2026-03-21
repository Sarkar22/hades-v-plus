# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 21.03.2026 19:31  
**Test Deadline:** 01.06.2026 00:00  
### Tested Commit Information
**Date:** 21.03.2026 14:38  
**Hash:** db7e107  
**Message:** fix(decode): combinatorial status_forwards_out with registered-state default  
**Committer Email:** esarkar@RF-LT05.eng.uwaterloo.ca  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   8.00 /  8  


</details>


# Module Under Test:  Decode Stage  
<details><summary>Details for the  Decode Stage</summary>

**Points:**   3.65 /  4  

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
### status_backwards_in = STALL while forwarding.data_valid = 0  
  
Test input: BEQ with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 0 | 
  
Test input: BEQ with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 0 | 
### status_backwards_in = STALL while forwarding.data_valid = 0  
  
Test input: SW with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 0 | 
### now status_backwards_in = READY, but forwarding.data_valid = 0 => insert BUBBLE  
  
Test input: SLT with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 0 | 
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
## raise ILLEGAL_INSTRUCTION  
### illegal instruction word, but status_backwards_in = STALL => ignore error  
  
Test input: ILLEGAL with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 0 | 
## STALL error  
### STALL error => ignore "new error"  
  
Test input: ILLEGAL with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 4 | 
### STALL error (old one)  
  
Test input: SRAI with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 1 | 4 | 
</details>


# Module Under Test:  Register File  
<details><summary>Details for the  Register File</summary>

**Points:**   4.00 /  4  


</details>

