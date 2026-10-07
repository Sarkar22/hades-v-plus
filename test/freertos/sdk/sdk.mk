# ---------------------------------------------------------------------------------------------
# sdk.mk -- the app SDK: programs built on the host for the app loader of the FreeRTOS shell
# (test/freertos/loader/SPEC.md, section 9). Included at the end of test/freertos/freertos.mk.
#
#   make freertos-app NAME=<name> [MARCH=rv32i|rv32im|rv32i_zba|rv32im_zba|rv32im_zba_zbb_zbs|
#                     rv32im_zba_zbb_zbkb_zbkx_zbs_zknh] [OPT=-O2|-Os|-O0] [VERBOSE=1]
#       build the app test/freertos/sdk/apps/<name>/ (every .c and .S file in it, with crt0.S
#       and app.ld; rv32i and -O2 by default) quietly, into $(SDK_OUT)/build.log, and print one
#       line: its sizes, its CRC-32 and its HEX file, $(SDK_OUT)/<march>/<name>.hex. <name>:
#       1 to 15 letters, digits, '_' or '-' (it is stored in the image header)
#   make freertos-apps
#       the example apps (rv32i; compute also for rv32im_zba, bitmanip also for
#       rv32im_zba_zbb_zbs, sha256 also for rv32im_zba_zbb_zbkb_zbkx_zbs_zknh) at -O2, and the
#       test files of the loader ($(SDK_OUT)/testfiles/); built before every console run of
#       APP=loader
#   make freertos-send UPLOAD=<app>
#       send the app to the running 'make freertos-shell APP=loader PTY=1': a send request
#       (<pty>.upload) asks the simulator's console bridge to type 'load' and send the file,
#       which it does only at the shell's prompt with nothing typed (or sends the file at once
#       to a 'load' that waits for one); its answer (<pty>.upload-answer) is printed, and a
#       refusal is an error
#
# UPLOAD=<name> is $(SDK_OUT)/rv32i/<name>.hex, UPLOAD=<march>/<name> the build for another
# -march, and a value ending in .hex is a file, used as it is. An app named by UPLOAD is
# rebuilt when it is out of date, at the optimisation level of its last build (-O2 if it has
# none), so that UPLOAD= sends the build that 'make freertos-app' made. $(call
# sdk_upload_file,<value>) is the absolute path of that file, and $(call
# sdk_upload_goal,<value>) the make goal that builds it (none for a .hex file).
#
# Output, in $(SDK_OUT)/<march>/: <name>.elf, .bin (the final image), .hex, .dis (of the ELF,
# whose header still lacks the name, the flags and the CRC-32), .map, and obj/<name>/ with the
# objects and flags.txt, the flags of the last build: an app is rebuilt when one of its
# sources, an SDK file or its flags change. A goal $(SDK_OUT)/<march>/<name>.hex builds that
# app (at SDK_BUILD_OPT if it is given, else as above for UPLOAD's app and at -O2 for others).
# ---------------------------------------------------------------------------------------------

SDK_DIR       = $(FRTOS_DIR)/sdk
SDK_OUT       = $(BUILD_ABS)/$(FRTOS_DIR)/sdk
SDK_MARCHES   = rv32i rv32im rv32i_zba rv32im_zba rv32im_zba_zbb_zbs rv32im_zba_zbb_zbkb_zbkx_zbs_zknh
SDK_EXAMPLES  = rv32i/hello rv32i/compute rv32i/crash rv32i/selfmod rv32i/upper rv32im_zba/compute \
                rv32i/bitmanip rv32im_zba_zbb_zbs/bitmanip rv32i/sha256 rv32im_zba_zbb_zbkb_zbkx_zbs_zknh/sha256
SDK_TESTFILES = $(SDK_OUT)/testfiles/tiny.hex
SDK_TOOL      = python3 $(SDK_DIR)/appimg.py
SDK_PTY       = $(BUILD_ABS)/$(FRTOS_DIR)/loader/pty
SDK_APP_NAMES = $(sort $(notdir $(patsubst %/,%,$(dir $(wildcard $(SDK_DIR)/apps/*/*.[cS])))))

# UPLOAD values: <name> or <march>/<name> is the build <march>/<name>.
sdk_build       = $(if $(findstring /,$(1)),$(1),rv32i/$(1))
sdk_upload_file = $(if $(filter %.hex,$(1)),$(abspath $(1)),$(SDK_OUT)/$(call sdk_build,$(1)).hex)
sdk_upload_goal = $(if $(filter %.hex,$(1)),,$(SDK_OUT)/$(call sdk_build,$(1)).hex)

# The knobs of freertos-app, honoured only on the command line (as the other short knobs).
SDK_NAME  = $(if $(filter command line,$(origin NAME)),$(NAME))
SDK_MARCH = $(if $(filter command line,$(origin MARCH)),$(MARCH),rv32i)
SDK_OPT   = $(if $(filter command line,$(origin OPT)),$(OPT),-O2)

# ---- one build of an app: $(1) = -march, $(2) = name ----
# The optimisation level: SDK_BUILD_OPT if it is given (freertos-app passes its OPT); for the
# app named by UPLOAD, the level of its last build (in its flags.txt), or -O2; else -O2.
SDK_UPLOAD_BUILD = $(if $(FRTOS_UPLOAD),$(if $(filter %.hex,$(FRTOS_UPLOAD)),,$(call sdk_build,$(FRTOS_UPLOAD))))
sdk_last_opt = $(firstword $(filter -O%,$(shell cat $(call sdk_obj_dir,$(1),$(2))/flags.txt 2>/dev/null)))
sdk_opt      = $(if $(filter command line,$(origin SDK_BUILD_OPT)),$(SDK_BUILD_OPT),$(if \
                   $(filter $(1)/$(2),$(SDK_UPLOAD_BUILD)),$(or $(call sdk_last_opt,$(1),$(2)),-O2),-O2))
sdk_obj_dir  = $(SDK_OUT)/$(1)/obj/$(2)
sdk_srcs     = $(sort $(wildcard $(SDK_DIR)/apps/$(1)/*.c $(SDK_DIR)/apps/$(1)/*.S))
sdk_objs     = $(call sdk_obj_dir,$(1),$(2))/crt0.o \
               $(foreach s,$(call sdk_srcs,$(2)),$(call sdk_obj_dir,$(1),$(2))/$(basename $(notdir $(s))).o)
# (std/include: peripherals.h, the addresses of the LEDs, switches, display and VGA.)
sdk_cflags   = -march=$(1) -mabi=ilp32 $(3) -g -ffunction-sections -fdata-sections -Wall -I$(SDK_DIR) \
               -I$(STD_LIB_DIR)/include -MMD -MP
sdk_ldflags  = -march=$(1) -mabi=ilp32 -nostdlib -nostartfiles -T $(SDK_DIR)/app.ld \
               -Wl,--gc-sections -Wl,--no-warn-rwx-segments
sdk_flags    = $(call sdk_cflags,$(1),$(2),$(3)) | $(call sdk_ldflags,$(1)) | $(call sdk_srcs,$(2))
sdk_check    = $(if $(and $(filter 2,$(words $(subst /, ,$(1)))),$(filter $(SDK_MARCHES),$(firstword $(subst /, ,$(1))))),,\
                   $(error '$(1)' is not an app build: <name> or <march>/<name>, with a -march out of $(SDK_MARCHES)))
# An app's name is stored in its image header: 1 to 15 of A-Z a-z 0-9 _ - (SPEC.md, 3.2).
sdk_check_app = $(if $(shell printf '%s' '$(1)' | grep -xE '[A-Za-z0-9_-]{1,15}'),,\
                   $(error app name '$(1)': 1 to 15 letters, digits, '_' or '-' (the name is stored in the image header)))$(if \
                   $(wildcard $(SDK_DIR)/apps/$(1)/*.[cS]),,\
                   $(error app '$(1)' not found (no .c or .S file in $(SDK_DIR)/apps/$(1)/). The apps: $(SDK_APP_NAMES)))
# The flags file is brought up to date while the makefile is parsed, as in freertos.mk.
# ($(3) = the optimisation level, $(call sdk_opt,$(1),$(2)), read before the file changes.)
sdk_sync     = $(shell mkdir -p $(call sdk_obj_dir,$(1),$(2)) && \
                   if [ "$$(cat $(call sdk_obj_dir,$(1),$(2))/flags.txt 2>/dev/null)" != '$(call sdk_flags,$(1),$(2),$(3))' ]; then \
                       echo '$(call sdk_flags,$(1),$(2),$(3))' > $(call sdk_obj_dir,$(1),$(2))/flags.txt; fi)

define sdk_rules
$(call sdk_obj_dir,$(1),$(2))/flags.txt:
	@ mkdir -p $$(@D)
	@ echo '$(call sdk_flags,$(1),$(2),$(3))' > $$@

$(call sdk_obj_dir,$(1),$(2))/crt0.o: $(SDK_DIR)/crt0.S $(call sdk_obj_dir,$(1),$(2))/flags.txt
	$$(CC) $(call sdk_cflags,$(1),$(2),$(3)) -c $$< -o $$@
$(call sdk_obj_dir,$(1),$(2))/%.o: $(SDK_DIR)/apps/$(2)/%.c $(call sdk_obj_dir,$(1),$(2))/flags.txt
	$$(CC) $(call sdk_cflags,$(1),$(2),$(3)) -c $$< -o $$@
$(call sdk_obj_dir,$(1),$(2))/%.o: $(SDK_DIR)/apps/$(2)/%.S $(call sdk_obj_dir,$(1),$(2))/flags.txt
	$$(CC) $(call sdk_cflags,$(1),$(2),$(3)) -c $$< -o $$@
-include $(wildcard $(call sdk_obj_dir,$(1),$(2))/*.d)

$(SDK_OUT)/$(1)/$(2).elf: $(call sdk_objs,$(1),$(2)) $(SDK_DIR)/app.ld $(call sdk_obj_dir,$(1),$(2))/flags.txt
	$$(CC) $(call sdk_ldflags,$(1)) -Wl,-Map=$(SDK_OUT)/$(1)/$(2).map -o $$@ $(call sdk_objs,$(1),$(2)) -lc_nano -lgcc
	$$(OBJDUMP) -d $$@ > $(SDK_OUT)/$(1)/$(2).dis

$(SDK_OUT)/$(1)/$(2).hex: $(SDK_OUT)/$(1)/$(2).elf $(SDK_DIR)/appimg.py
	$$(OBJCOPY) -O binary $$< $(SDK_OUT)/$(1)/$(2).bin
	@ $(SDK_TOOL) hex --name $(2) --march $(1) --opt='$(3)' $(SDK_OUT)/$(1)/$(2).bin $$@
endef

# The app builds given as goals of this make run, $(SDK_OUT)/<march>/<name>.hex: their rules
# and their flags files (nothing for any other goal). When freertos-apps is a goal as well (a
# console run of the loader with UPLOAD=), its sub-make builds them, so that two makes never
# build the same app at once (make -j).
SDK_GOALS := $(sort $(patsubst $(SDK_OUT)/%.hex,%,$(filter-out $(SDK_TESTFILES),$(filter $(SDK_OUT)/%.hex,$(MAKECMDGOALS)))))
$(foreach b,$(SDK_GOALS),$(call sdk_check,$(b))$(call sdk_check_app,$(lastword $(subst /, ,$(b)))))
ifeq ($(filter freertos-apps,$(MAKECMDGOALS)),)
sdk_build_opt = $(call sdk_opt,$(firstword $(subst /, ,$(1))),$(lastword $(subst /, ,$(1))))
$(foreach b,$(SDK_GOALS),$(eval SDK_OPT_$(b) := $(call sdk_build_opt,$(b))))
$(foreach b,$(SDK_GOALS),$(eval $(call sdk_rules,$(firstword $(subst /, ,$(b))),$(lastword $(subst /, ,$(b))),$(SDK_OPT_$(b)))))
SDK_FLAGS_SYNC := $(foreach b,$(SDK_GOALS),$(call sdk_sync,$(firstword $(subst /, ,$(b))),$(lastword $(subst /, ,$(b))),$(SDK_OPT_$(b))))
else
$(foreach b,$(SDK_GOALS),$(eval $(SDK_OUT)/$(b).hex: freertos-apps ; @ :))
endif

$(SDK_TESTFILES): $(SDK_DIR)/appimg.py
	@ $(SDK_TOOL) testfiles $(@D)

# The app names given on the command line are checked here, before anything is built (a
# sub-make would report them after its own failure).
ifneq ($(and $(SDK_NAME),$(filter freertos-app,$(MAKECMDGOALS))),)
$(call sdk_check,$(SDK_MARCH)/$(SDK_NAME))$(call sdk_check_app,$(SDK_NAME))
endif
ifneq ($(and $(SDK_UPLOAD_BUILD),$(filter freertos-shell freertos-send,$(MAKECMDGOALS))),)
$(call sdk_check,$(SDK_UPLOAD_BUILD))$(call sdk_check_app,$(lastword $(subst /, ,$(SDK_UPLOAD_BUILD))))
endif

# ---- front end ----
# Builds the goals $(1) in a sub-make, quietly into $(SDK_OUT)/build.log (VERBOSE=1 shows
# everything), and prints the line of every app it built, or "($(2))" if it built none.
define sdk_quiet_build
@ mkdir -p $(SDK_OUT)
@ if [ -n "$(VERBOSE)" ]; then $(MAKE) --no-print-directory $(1); else \
      $(MAKE) --no-print-directory $(1) > $(SDK_OUT)/build.log 2>&1 || \
      { tail -n 40 $(SDK_OUT)/build.log; echo "BUILD FAILED -- full log: $(SDK_OUT)/build.log"; exit 1; }; \
      grep -a '^app ' $(SDK_OUT)/build.log || echo "  ($(2))"; fi
endef

.PHONY: freertos-app freertos-apps freertos-send
freertos-app:
	@ case '$(SDK_NAME)' in '') echo "usage: make freertos-app NAME=<name> [MARCH=rv32i|rv32im|rv32i_zba|rv32im_zba|rv32im_zba_zbb_zbs|rv32im_zba_zbb_zbkb_zbkx_zbs_zknh] [OPT=-O2|-Os|-O0]   (apps: $(SDK_APP_NAMES))"; exit 1;; esac
	$(call sdk_quiet_build,$(SDK_OUT)/$(SDK_MARCH)/$(SDK_NAME).hex SDK_BUILD_OPT='$(SDK_OPT)',app $(SDK_NAME) [$(SDK_MARCH) $(SDK_OPT)] up to date: $(SDK_OUT)/$(SDK_MARCH)/$(SDK_NAME).hex)

freertos-apps:
	$(call sdk_quiet_build,$(sort $(foreach b,$(SDK_EXAMPLES) $(SDK_GOALS),$(SDK_OUT)/$(b).hex)) $(SDK_TESTFILES),example apps and test files up to date: $(SDK_OUT))

# The session's pseudo-terminal must belong to a running simulator: a link left behind by one
# that was killed may point to a device that some other terminal uses now. The request is
# written in one step (renamed into place); the bridge looks for it every 8192 cycles and
# answers within a fraction of a second. SDK_SEND_WAIT: how long to wait for the answer, in
# tenths of a second.
SDK_SEND_WAIT = 300
freertos-send:
	@ case '$(FRTOS_UPLOAD)' in '') echo "usage: make freertos-send UPLOAD=<app>   (<name>, <march>/<name> or a .hex file; apps: $(SDK_APP_NAMES))"; exit 1;; esac
	$(if $(call sdk_upload_goal,$(FRTOS_UPLOAD)),$(call sdk_quiet_build,$(call sdk_upload_goal,$(FRTOS_UPLOAD)),app up to date: $(call sdk_upload_file,$(FRTOS_UPLOAD))))
	@ f='$(call sdk_upload_file,$(FRTOS_UPLOAD))'; p='$(SDK_PTY)'; \
	  if [ ! -r "$$f" ]; then echo "freertos-send: cannot read $$f"; exit 1; fi; \
	  if [ ! -c "$$p" ] || ! ps -ww -eo args | awk -v a="+console_pty_link=$$p" \
	        '{ for (i = 2; i <= NF; i++) if ($$i == a) n++ } END { exit n == 0 }'; then \
	      echo "freertos-send: no loader session with a pseudo-terminal is running ($$p): start one with 'make freertos-shell APP=loader PTY=1'"; \
	      exit 1; fi; \
	  rm -f "$$p.upload-answer"; \
	  printf '%s\n' "$$f" > "$$p.upload.tmp" && mv -f "$$p.upload.tmp" "$$p.upload" || exit 1; \
	  i=0; while [ ! -e "$$p.upload-answer" ] && [ $$i -lt $(SDK_SEND_WAIT) ]; do sleep 0.1; i=$$((i + 1)); done; \
	  if [ ! -e "$$p.upload-answer" ]; then rm -f "$$p.upload"; \
	      echo "freertos-send: the simulator did not answer within $$(($(SDK_SEND_WAIT) / 10)) seconds; nothing was sent"; exit 1; fi; \
	  a=$$(cat "$$p.upload-answer"); rm -f "$$p.upload-answer"; \
	  case "$$a" in \
	      ok) echo "send: 'load' and $$f ($$(wc -c < "$$f") bytes) -> $$p";; \
	      'ok waiting') echo "send: $$f ($$(wc -c < "$$f") bytes) -> $$p, to the 'load' that was waiting";; \
	      *) echo "freertos-send: not sent: $${a#refused: }"; exit 1;; \
	  esac
