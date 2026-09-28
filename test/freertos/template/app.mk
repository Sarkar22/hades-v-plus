# template: starting point for your own program (copy it: make freertos-new NAME=<name>)
#
# This file tells test/freertos/freertos.mk how to build the program. APP_DIR is the
# program's own directory (test/freertos/<name>), so the file works unchanged in a copy.

# Your sources: every .c and .S file in this directory.
APP_SRCS        := $(wildcard $(APP_DIR)/*.c $(APP_DIR)/*.S)

# FreeRTOS kernel files. tasks.c, queue.c and list.c cover tasks, queues, semaphores,
# mutexes and task notifications. Add timers.c for software timers (and set
# configUSE_TIMERS to 1 in app_config.h), event_groups.c for event groups, and
# stream_buffer.c for stream and message buffers.
APP_KERNEL_SRCS := tasks.c queue.c list.c

# RAM size in KiB. 32 is the real Basys3 board. Larger values (64, 128, 256, ...) exist
# only in simulation; the matching simulator is built automatically.
APP_RAM_KB      := 32

# Bytes at the top of RAM for main()'s stack before the scheduler starts and for the
# interrupt stack afterwards. The run fails if fewer than 64 of them were never used.
APP_ISR_STACK   := 1024

# Simulation cycle limit; TIMEOUT=<cycles> on the command line overrides it.
APP_TIMEOUT     := 20000000
