# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 24.03.2026 05:36  
**Test Deadline:** 02.06.2026 00:00  
### Tested Commit Information
**Date:** 24.03.2026 00:35  
**Hash:** 25ea0af  
**Message:** Implement memory_stage.sv  
**Committer Email:** esarkar@RF-LT05.eng.uwaterloo.ca  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   8.00 /  8  


</details>


# Module Under Test:  Decode Stage  
<details><summary>Details for the  Decode Stage</summary>

**Points:**   4.00 /  4  


</details>


# Module Under Test:  Register File  
<details><summary>Details for the  Register File</summary>

**Points:**   4.00 /  4  


</details>


# Module Under Test:  Instruction Decoder  
<details><summary>Details for the  Instruction Decoder</summary>

**Points:**   4.00 /  4  


</details>


# Module Under Test:  Execute Stage  
<details><summary>Details for the  Execute Stage</summary>

**Points:**  10.00 / 10  


</details>


# Module Under Test:  Memory Stage  
<details><summary>Details for the  Memory Stage</summary>

**Points:**   9.47 / 10  

## delayed wishbone acknowledge  
### ack 2 cycles delayed  
  
Test input: SH with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 1 | 
  
Test input: SH with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_forwards_out | 0 | 1 | 
</details>

