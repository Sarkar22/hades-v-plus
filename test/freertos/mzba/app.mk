# mzba: M and Zba code under the RTOS, checked against an rv32i software build of the same code; 32 KiB
#
# M-extension and Zba code under the RTOS. kernels.c is compiled twice: with the
# program's -march (native mul/div/sh*add) and, as an independent software reference,
# for plain rv32i (libgcc division/multiplication, no Zba). divstorm.S (only with M) runs
# back-to-back divides so that the tick and the external interrupt land inside the
# 34-cycle divide stall of Execute.
APP_SRCS     := $(FRTOS_DIR)/mzba/main.c $(FRTOS_DIR)/mzba/kernels.c $(FRTOS_DIR)/mzba/divstorm.S \
                $(FREERTOS_DEMO)/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S
APP_REF_SRCS := $(FRTOS_DIR)/mzba/kernels.c
APP_RAM_KB   := 32
APP_ISR_STACK := $(if $(filter -O0,$(FRTOS_OPT)),2048,1024)
