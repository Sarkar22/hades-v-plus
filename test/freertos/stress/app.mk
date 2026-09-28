# stress: RegTest, desynchronised queues, ISR-fed semaphores, critical-section and slow-bus checks; 32 KiB
#
# RegTest + desynchronised queues + ISR-fed semaphore/notifications from the
# wishbone_test interrupt + critical-section/yield checks + tick drift. Fits 32 KiB
# at -O2/-Os (the campaign runs -O0 with 64 KiB, see campaign.py).
APP_SRCS    := $(FRTOS_DIR)/stress/main.c $(FRTOS_DIR)/stress/regtest3.S \
               $(FREERTOS_DEMO)/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S
APP_RAM_KB  := 32
# measured ISR/main stack peak: <= 188 bytes at -O2/-Os (hal_pass() fails if <64 bytes remain);
# 640 (not 768) leaves room for the STRESS_SLOWBUS idle hook in the 32 KiB board RAM
APP_ISR_STACK := $(if $(filter -O0,$(FRTOS_OPT)),2048,640)
