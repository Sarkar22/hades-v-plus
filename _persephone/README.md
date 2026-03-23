# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 24.03.2026 00:05  
**Test Deadline:** 04.06.2026 00:00  
### Tested Commit Information
**Date:** 21.03.2026 21:40  
**Hash:** d03caec  
**Message:** minor formatting  
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

## raise FETCH_MISALIGNED  
  
Test input: JALR with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| jump_address_backwards_out | 0x44444443 | 0x44444442 | 
  
Test input: JALR with status_backwards_in = READY and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| jump_address_backwards_out | 0x88888885 | 0x88888884 | 
| next_program_counter_reg_out | 0x88888885 | 0x88888884 | 
| status_forwards_out | 2 | 0 | 
### STALL => ignore error  
  
Test input: JALR with status_backwards_in = STALL and status_forwards_in = VALID  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data_valid | 0 | 1 | 
</details>

