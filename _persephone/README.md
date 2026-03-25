# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 25.03.2026 13:06  
**Test Deadline:** 02.06.2026 00:00  
### Tested Commit Information
**Date:** 25.03.2026 07:38  
**Hash:** 1a13337  
**Message:** Implement writeback_stage.sv  
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

**Points:**  14.36 / 16  

## CSR-operations  
### MSTATUS - do only consider MPIE and MIE  
  
Test input: CSRRWI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MSTATUS  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x11112222 | 0x00000080 | 
  
Test input: CSRRSI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MSTATUS  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x0000001f | 0x00000008 | 
  
Test input: CSRRCI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MSTATUS  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x00000018 | 0x00000008 | 
### MTVEC - set LSBs = 0  
  
Test input: CSRRWI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MTVEC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xaaaabbbb | 0xdabbad00 | 
  
Test input: CSRRSI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MTVEC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x0000001f | 0x00000008 | 
### MSCRATCH  
  
Test input: CSRRWI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MSCRATCH  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xaaaabbbb | 0xbaadf00d | 
  
Test input: CSRRSI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MSCRATCH  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x0000001f | 0x00000008 | 
### MEPC - set LSBs = 0!  
  
Test input: CSRRWI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x11112222 | 0xfaceb00c | 
  
Test input: CSRRSI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x0000001f | 0x00000008 | 
### MCAUSE  
  
Test input: CSRRSI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MCAUSE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x0000001f | 0x00000008 | 
## CSR-operation with rd=x0/src=0/imm=0  
### immediate = 0  
  
Test input: CSRRWI with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MEPC  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xeeeeffff | 0xfaceb00c | 
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
## trigger Interrupt immediatly (enable when already pending)  
### MSTATUS[MIE] = 1  
  
Test input: CSRRS with status_forwards_in = VALID and external/timer interrupt = 1/0, csr = MSTATUS  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 2 | 
| jump_address_backwards_out | 0x00000000 | 0xdabbad00 | 
### MIE[MTIE] = 1  
  
Test input: CSRRS with status_forwards_in = VALID and external/timer interrupt = 0/1, csr = MIE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| status_backwards_out | 0 | 2 | 
| jump_address_backwards_out | 0x00000000 | 0xdabbad00 | 
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
## check MCYCLE and MINSTRET  
### check MCYCLE  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MCYCLE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x76543215 | 0x76543216 | 
### check MINSTRET  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MINSTRET  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0x76543212 | 0x76543213 | 
## check MCYCLE: increment first, then write  
### write to MCYCLE  
  
Test input: CSRRW with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MCYCLE  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xfffffffe | 0xffffffff | 
### check MCYCLE  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MCYCLEH  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xbadc0ded | 0xbadc0dee | 
## check MINSTRET  
### write to MINSTRET  
  
Test input: CSRRW with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MINSTRET  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xfffffffe | 0xffffffff | 
### check MINSTRET  
  
Test input: CSRRC with status_forwards_in = VALID and external/timer interrupt = 0/0, csr = MINSTRETH  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| forwarding_out.data | 0xbadc0ded | 0xbadc0dee | 
</details>

