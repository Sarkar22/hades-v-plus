# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 21.03.2026 07:31  
**Test Deadline:** 01.06.2026 00:00  
### Tested Commit Information
**Date:** 21.03.2026 02:36  
**Hash:** 33359bf  
**Message:** Fix decode stage and instruction decoder based on Persephone feedback  
**Committer Email:** esarkar@RF-LT05.eng.uwaterloo.ca  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   8.00 /  8  


</details>


# Module Under Test:  Decode Stage  
<details><summary>Details for the  Decode Stage</summary>

**Points:**   3.88 /  4  

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
## raise ILLEGAL_INSTRUCTION  
### invalid CSR-address  
  
Test input: CSRRW with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 4 | 
  
Test input: CSRRS with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 4 | 
  
Test input: CSRRC with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 4 | 
  
Test input: CSRRW with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 4 | 
### invalid CSR access  
  
Test input: CSRRS with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 4 | 
  
Test input: CSRRCI with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 4 | 
</details>


# Module Under Test:  Register File  
<details><summary>Details for the  Register File</summary>

**Points:**   4.00 /  4  


</details>

