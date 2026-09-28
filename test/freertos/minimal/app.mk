# minimal: two application tasks + idle (notification ping-pong, idle progress, tick drift); 32 KiB
#
# Two application tasks + idle; must fit the real 32 KiB RAM.
APP_SRCS    := $(FRTOS_DIR)/minimal/main.c
APP_RAM_KB  := 32
