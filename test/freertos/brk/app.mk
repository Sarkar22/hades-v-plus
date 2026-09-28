# brk: RTOS-level breaker: interrupt storms, tick catch-up, task churn, fence.i, deliberate exceptions; 64 KiB
#
# RTOS-level breaker. Interrupt storms far shorter than the tick feeding
# stream/message buffers from the ISR (and an ISR-drained task->ISR stream buffer),
# mtimecmp written into the past / near future and multi-tick critical sections
# (tick catch-up), nested critical sections, taskYIELD() with interrupts disabled,
# task churn with vTaskDelete (self and other), a priority-inheritance mutex chain,
# self-modifying code with fence.i from tasks, runtime branch-predictor mode changes
# (MHPMEVENT10; a no-op on the golden CPU), register-integrity asm (divides adjacent
# to CSR/ECALL/slow-bus ops with M), RegTest 1/2/3. 64 KiB RAM (sim), 256 KiB at -O0.
APP_SRCS        := $(FRTOS_DIR)/brk/main.c $(FRTOS_DIR)/brk/pipebrk.S $(FRTOS_DIR)/stress/regtest3.S \
                   $(FREERTOS_DEMO)/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S
APP_KERNEL_SRCS := tasks.c queue.c list.c stream_buffer.c
APP_RAM_KB      := $(if $(filter -O0,$(FRTOS_OPT)),256,64)
APP_ISR_STACK   := 2048
