# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 28.03.2026 07:06  
**Test Deadline:** 02.06.2026 00:00  
### Tested Commit Information
**Date:** 28.03.2026 01:39  
**Hash:** 7335bbd  
**Message:** more fix for writeback  
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

**Points:**  10.00 / 10  


</details>


# Module Under Test:  Writeback Stage  
<details><summary>Details for the  Writeback Stage</summary>

**Points:**  15.61 / 16  

## trigger Interrupt (already enabled)  
### check CSRs  
  
Test input: CSRRW with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00040010 | 0x00040014 | 
### check CSRs  
  
Test input: CSRRW with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00040060 | 0x00040064 | 
## MRET after Interrupt with MSTATUS[MIE] = 1  
### MRET  
  
Test input: MRET with status_forwards_in = VALID and external/timer interrupt = 0/0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| jump_address_backwards_out | 0x00040034 | 0x00040038 | 
## MRET while Interrupt pending  
### MRET -> directly trigger Interrupt again  
  
Test input: MRET with status_forwards_in = VALID and external/timer interrupt = 1/0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| jump_address_backwards_out | 0x00040058 | 0xdabbad00 | 
### check MEPC (no change)  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 1/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00040058 | 0x0004005c | 
### MRET -> jump to old MEPC  
  
Test input: MRET with status_forwards_in = VALID and external/timer interrupt = 0/0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| jump_address_backwards_out | 0x00040058 | 0x0004005c | 
## special Interrupt cases  
### check CSRs  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 1/0, csr = MSTATUS  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00000000 | 0x00000080 | 
### MRET from Exception while Interrupt pending  
  
Test input: MRET with status_forwards_in = VALID and external/timer interrupt = 1/0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| jump_address_backwards_out | 0x00040018 | 0xdabbad00 | 
### check CSRs  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 1/0, csr = MCAUSE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00000001 | 0x8000000b | 
## check MCYCLE: increment first, then write  
### check MCYCLE  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MCYCLE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xbaaaaaae | 0xbaaaaaad | 
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MCYCLEH  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xbadc0ded | 0xbadc0dee | 
## check MINSTRET  
### check MINSTRET  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MINSTRET  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xbaaaaaae | 0xbaaaaaad | 
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MINSTRETH  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xbadc0ded | 0xbadc0dee | 
</details>

