# loader: the shell with an app loader: run programs built on the host; 256 KiB, simulation only
#
# test/freertos/loader/SPEC.md. The shell's sources (test/freertos/shell/) compiled with
# SHELL_LOADER=1, plus loader.c: the commands load, run and app. The SDK and the example apps
# are in test/freertos/sdk/. Interactive: make freertos-shell APP=loader [UPLOAD=<app>]
# [PTY=1]; scripted: make freertos-shell-test APP=loader (session.txt).
ifeq ($(wildcard $(FREERTOS_PLUS_CLI)/FreeRTOS_CLI.c),)
$(error FreeRTOS+CLI not found at $(FREERTOS_PLUS_CLI). It is part of the repository, in third_party/freertos/: if FREERTOS_HOME or FREERTOS_PLUS_CLI is set, unset it or point it to a complete checkout; if files are missing, restore them with 'git checkout -- third_party/freertos'. See docs/FREERTOS.md)
endif
APP_SRCS         := $(FRTOS_DIR)/shell/main.c $(FRTOS_DIR)/shell/console.c \
                    $(FRTOS_DIR)/shell/commands.c $(FRTOS_DIR)/shell/format.c \
                    $(FREERTOS_PLUS_CLI)/FreeRTOS_CLI.c $(APP_DIR)/loader.c
# The software model of M and Zba is always compiled for plain rv32i.
APP_REF_SRCS     := $(FRTOS_DIR)/shell/swmodel.c
APP_INCLUDES     := -I$(FREERTOS_PLUS_CLI) -I$(FRTOS_DIR)/shell -I$(FRTOS_DIR)/sdk
APP_KERNEL_SRCS  := tasks.c queue.c list.c
APP_DEFS         := -DSHELL_LOADER=1 -DSHELL_RX_BUFFER=128
# -Os unless OPT= is given, as for the shell; every level fits the shell's 128 KiB.
ifeq ($(filter command line,$(origin OPT) $(origin FRTOS_OPT)),)
FRTOS_OPT        := -Os
endif
# The simulated RAM; the shell is linked for its first 128 KiB, the app slot follows.
APP_RAM_KB       := 256
APP_LINK_KB      := 128
APP_ISR_STACK    := 1024
# Cycle limit of a scripted session; an interactive one has none unless TIMEOUT= is given.
APP_TIMEOUT      := 300000000
# Reads the UART: run it with the console targets (make freertos-shell APP=loader, ...).
APP_CONSOLE      := 1
# The example apps and the test files, built before every console run, and where the console
# bridge finds them. (Recursive '=': SDK_OUT is defined by sdk.mk, included later.)
APP_CONSOLE_DEPS := freertos-apps
APP_CONSOLE_ARGS  = +console_upload_dir=$(SDK_OUT)
APP_TTY_TEST     := $(APP_DIR)/tty_test.py
APP_TTY_ARGS      = --upload-dir $(SDK_OUT)
