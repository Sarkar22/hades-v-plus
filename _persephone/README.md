# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 21.03.2026 20:31  
**Test Deadline:** 01.06.2026 00:00  
### Tested Commit Information
**Date:** N/A  
**Hash:** N/A  
**Message:** N/A  
**Committer Email:** N/A  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   8.00 /  8  


</details>


# Module Under Test:  Decode Stage  
<details><summary>Details for the  Decode Stage</summary>

**Points:**   3.95 /  4  

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

