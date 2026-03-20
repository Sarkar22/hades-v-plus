# Testcase Results 

**Repository:** hades-v_9_Sarkar22  
**Test Run:** 20.03.2026 05:31  
**Test Deadline:** 01.06.2026 00:00  
### Tested Commit Information
**Date:** 20.03.2026 00:39  
**Hash:** b574fff  
**Message:** Exercise 2: implement fetch_stage.sv  
**Committer Email:** esarkar@RF-LT05.eng.uwaterloo.ca  

# Module Under Test:  Fetch Stage  
<details><summary>Details for the  Fetch Stage</summary>

**Points:**   6.17 /  8  

## simple fetch  
### status_backwards_in = READY followed by STALL  
  
Test input: status_backwards_in = STALL, wb.ack = 1, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
### status_backwards_in = READY followed by 2x STALL  
  
Test input: status_backwards_in = STALL, wb.ack = 1, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
  
Test input: status_backwards_in = STALL, wb.ack = 1, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
### status_backwards_in = READY followed by 3x STALL  
  
Test input: status_backwards_in = STALL, wb.ack = 1, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
  
Test input: status_backwards_in = STALL, wb.ack = 1, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
  
Test input: status_backwards_in = STALL, wb.ack = 1, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
## raise FETCH_FAULT  
### STALL => ignore error  
  
Test input: status_backwards_in = STALL, wb.ack = 0, wb.err = 1  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
### STALL => ignore error  
  
Test input: status_backwards_in = STALL, wb.ack = 0, wb.err = 1  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
### STALL => ignore error  
  
Test input: status_backwards_in = STALL, wb.ack = 0, wb.err = 1  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
## delayed wishbone acknowledge  
### STALL + ack=0 => STALL  
  
Test input: status_backwards_in = STALL, wb.ack = 0, wb.err = 0  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
## delayed wishbone error  
### STALL + err=1 => ignore error  
  
Test input: status_backwards_in = STALL, wb.ack = 0, wb.err = 1  
| Signal | Is Value | Expected Value |   
| - | - | - |  
| wb.cyc | 0 | 1 | 
| wb.stb | 0 | 1 | 
</details>

