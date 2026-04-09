# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 09.04.2026 03:06  
**Test Deadline:** 02.06.2026 00:00  
### Tested Commit Information
**Date:** 08.04.2026 21:00  
**Hash:** f2d2ccf  
**Message:** Fix writeback: counter reads, interrupt timing, minstret stale  
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

**Points:**  15.52 / 16  

## trigger Interrupt immediatly (enable when already pending)  
### MSTATUS[MIE] = 1  
  
Test input: CSRRS with status_forwards_in = VALID and external/timer interrupt = 1/0, csr = MSTATUS  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 2 | 
| jump_address_backwards_out | 0x00000000 | 0xdabbad00 | 
### check CSRs  
  
Test input: CSRRW with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xfaceb00c | 0x00040014 | 
### MIE[MTIE] = 1  
  
Test input: CSRRS with status_forwards_in = VALID and external/timer interrupt = 0/1, csr = MIE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 2 | 
| jump_address_backwards_out | 0x00000000 | 0xdabbad00 | 
### check CSRs  
  
Test input: CSRRW with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00040018 | 0x00040038 | 
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
</details>

