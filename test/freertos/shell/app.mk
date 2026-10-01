# shell: interactive command shell (FreeRTOS+CLI) on the UART; make freertos-shell; 32 KiB
#
# Interrupt-driven UART receive -> queue -> console task (line editing) ->
# FreeRTOS+CLI commands: task list, run-time statistics, heap, counters, branch
# predictor, M/Zba calculator. Interactive: `make freertos-shell` (same terminal, or
# PTY=1 for screen/picocom); `make freertos-shell-test` runs session.txt and checks the
# transcript. FreeRTOS+CLI is vendored with the other FreeRTOS sources
# (third_party/freertos, FREERTOS_PLUS_CLI in freertos.mk).
ifeq ($(wildcard $(FREERTOS_PLUS_CLI)/FreeRTOS_CLI.c),)
$(error FreeRTOS+CLI not found at $(FREERTOS_PLUS_CLI). It is part of the repository, in third_party/freertos/: if FREERTOS_HOME or FREERTOS_PLUS_CLI is set, unset it or point it to a complete checkout; if files are missing, restore them with 'git checkout -- third_party/freertos'. See docs/FREERTOS.md)
endif
APP_SRCS        := $(APP_DIR)/main.c $(APP_DIR)/console.c $(APP_DIR)/commands.c $(APP_DIR)/format.c \
                   $(FREERTOS_PLUS_CLI)/FreeRTOS_CLI.c
# The software model of M and Zba is always compiled for plain rv32i.
APP_REF_SRCS    := $(APP_DIR)/swmodel.c
APP_INCLUDES    := -I$(FREERTOS_PLUS_CLI)
APP_KERNEL_SRCS := tasks.c queue.c list.c
# Built with -Os unless OPT= is given: so it fits the board's 32 KiB. Other levels need
# a larger (simulation-only) RAM.
ifeq ($(filter command line,$(origin OPT) $(origin FRTOS_OPT)),)
FRTOS_OPT       := -Os
endif
APP_RAM_KB      := $(if $(filter -Os,$(FRTOS_OPT)),32,64)
APP_ISR_STACK   := 512
# Cycle limit of a scripted session (make freertos-shell-test); an interactive session
# (make freertos-shell) has none unless TIMEOUT= is given.
APP_TIMEOUT     := 50000000
# Reads the UART: run it with make freertos-shell / freertos-shell-test (sim/console.cpp),
# not with make freertos, where nothing would ever arrive on its receive line.
APP_CONSOLE     := 1
