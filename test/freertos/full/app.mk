# full: the FreeRTOS standard demo task set (official RISC-V QEMU full_demo) + RegTest; 256 KiB, simulation only
#
# The FreeRTOS standard demo ("Common/Minimal") task set as used by the official
# RISC-V QEMU full_demo, plus RegTest and a check task. Needs the enlarged simulation
# RAM (FRTOS_RAM_KB=256 -> simulator verilated with HADES_MEMORY_SIZE_WORDS=65536).
APP_SRCS        := $(FRTOS_DIR)/full/main.c \
                   $(FREERTOS_DEMO)/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S
APP_KERNEL_SRCS := tasks.c queue.c list.c timers.c event_groups.c stream_buffer.c
APP_DEMO_SRCS   := blocktim.c dynamic.c GenQTest.c recmutex.c TimerDemo.c EventGroupsDemo.c \
                   TaskNotify.c AbortDelay.c countsem.c MessageBufferDemo.c StreamBufferDemo.c \
                   StreamBufferInterrupt.c QueueOverwrite.c QueueSet.c semtest.c BlockQ.c PollQ.c \
                   IntSemTest.c
APP_RAM_KB      := 256
APP_ISR_STACK   := 4096
# 3 check periods of 5000 ticks (150M cycles at the default 10000-cycle tick) + margin
APP_TIMEOUT     := $(shell echo $$(( 22500 * $(FRTOS_TICK) + 12000000 )))
