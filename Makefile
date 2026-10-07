CC ?= cc
CFLAGS ?= -O3 -std=c99 -Wall -Wextra -Wpedantic
FRAMA_C ?= frama-c
CLANG_FORMAT := $(shell command -v clang-format-20 2>/dev/null || \
	command -v clang-format 2>/dev/null)
C_SOURCES := $(wildcard *.c *.h)
SAMPLE_STATE := 21345671111111
SAMPLE_SOLUTION := B' R' D2 R' B R B' R D2 B R'
VECTORS := tests/solutions.txt
# One per rejection path: short, long, cubie digit low, cubie digit high,
# orientation digit low, orientation digit high, non-digit, duplicate, parity.
INVALID_STATES := 1234567111111 123456711111111 02345671111111 82345671111111 \
	12345671111110 12345671111114 1234567111111a 11345671111111 12345671111112

.PHONY: all check prove clean indent asm iret size FORCE

all: solver mini

solver: solver.c
	$(CC) $(CFLAGS) $< -o $@

mini: mini.c
	$(CC) $(CFLAGS) $< -o $@

gen_tables: gen_tables.c
	$(CC) $(CFLAGS) $< -o $@

tables.h tables.s &: gen_tables
	./gen_tables

ida: ida.c tables.h
	$(CC) $(CFLAGS) $< -o $@

scan: scan.c ida.c tables.h
	$(CC) $(CFLAGS) $< -o $@

# Ripes has no .if, so the GNU preprocessor expands #if RENDER, #include and
# STATE into plain assembly. One source yields a CLI build (measurable with
# --iret) and a GUI build (drives the LED matrix); they differ only in RENDER.
RV_CPP ?= riscv64-unknown-elf-cpp
RV_CPPFLAGS = -P -x assembler-with-cpp -DSTATE='"$(STATE)"'
ASM_SRC ?= rubik.S
STATE ?= $(SAMPLE_STATE)
PROC ?= RV32_ISS

build/rubik-cli.s: $(ASM_SRC) tables.s FORCE
	@mkdir -p build
	$(RV_CPP) $(RV_CPPFLAGS) -DRENDER=0 $< -o $@

build/rubik-gui.s: $(ASM_SRC) tables.s FORCE
	@mkdir -p build
	$(RV_CPP) $(RV_CPPFLAGS) -DRENDER=1 $< -o $@

asm: build/rubik-cli.s build/rubik-gui.s

iret: build/rubik-cli.s
	@test -n "$(RIPES)" || { echo "RIPES is unset; source env.sh"; exit 1; }
	$(RIPES) --mode cli -t asm --src $< --proc $(PROC) --iret --exectime

# Code size of the CLI build. --no-relax keeps every la as auipc + addi,
# which is what Ripes executes, so the bytes match the instructions counted.
RV_PREFIX ?= riscv64-unknown-elf-
size: build/rubik-cli.s
	$(RV_PREFIX)as -march=rv32i -mabi=ilp32 $< -o build/rubik-cli.o
	$(RV_PREFIX)ld -m elf32lriscv --no-relax -e 0 build/rubik-cli.o -o build/rubik-cli.elf
	$(RV_PREFIX)size -A build/rubik-cli.elf | awk '$$1 ~ /^\.(text|data|bss|rodata)$$/'

FORCE:

check: solver mini $(VECTORS)
	./solver --self-test
	@expected=$$(mktemp); actual=$$(mktemp); \
		trap 'rm -f "$$expected" "$$actual"' 0 1 2 15; \
		count=0; \
		while IFS='|' read -r state solution; do \
			case "$$state" in ""|\#*) continue ;; esac; \
			printf '%s\n' "$$solution" >"$$expected"; \
			for binary in ./solver ./mini; do \
				$$binary "$$state" >"$$actual"; \
				status=$$?; \
				test $$status -eq 0 || { \
					echo "$$binary $$state: exit status $$status"; exit 1; }; \
				cmp -s "$$actual" "$$expected" || { \
					echo "$$binary $$state: output mismatch"; \
					echo "  expected: $$solution"; \
					printf '  got:      '; cat "$$actual"; \
					echo "  ($$(wc -c <"$$expected") bytes expected, \
$$(wc -c <"$$actual") produced)"; exit 1; }; \
			done; \
			count=$$((count + 1)); \
		done <$(VECTORS); \
		echo "$$count solution vectors matched by solver and mini"
	@for binary in ./solver ./mini; do \
		for bad in $(INVALID_STATES); do \
			$$binary "$$bad" >/dev/null 2>&1; \
			status=$$?; \
			test $$status -eq 2 || { \
				echo "$$binary $$bad: expected status 2, got $$status"; exit 1; }; \
		done; \
		$$binary >/dev/null 2>&1; \
		status=$$?; \
		test $$status -eq 2 || { \
			echo "$$binary with no argument: expected status 2, got $$status"; \
			exit 1; }; \
		$$binary $(SAMPLE_STATE) $(SAMPLE_STATE) >/dev/null 2>&1; \
		status=$$?; \
		test $$status -eq 2 || { \
			echo "$$binary with two arguments: expected status 2, got $$status"; \
			exit 1; }; \
		$$binary $(SAMPLE_STATE) >&- 2>/dev/null; \
		status=$$?; \
		test $$status -eq 1 || { \
			echo "$$binary with stdout closed: expected status 1, got $$status"; \
			exit 1; }; \
	done
	@./solver --self-test >&- 2>/dev/null; \
		status=$$?; \
		test $$status -eq 1 || { \
			echo "solver --self-test with stdout closed: expected 1, got $$status"; \
			exit 1; }
	@echo "invalid input rejected with status 2, unwritable stdout with status 1"

prove: solver.c
	@log=$$(mktemp); trap 'rm -f "$$log"' 0 1 2 15; \
		$(FRAMA_C) -wp -wp-fct quarter_turn,rank_state,valid,parse_state \
		-wp-rte -rte-verbose 0 -wp-prover alt-ergo -wp-timeout 20 \
		-wp-cache none solver.c >"$$log" 2>&1; rc=$$?; \
		grep -Fvx -e '[wp] Warning: Skipped RTE guards: unaligned pointers (\aligned not supported)' \
		-e '[wp] Warning: Skipped RTE guards: invalid function pointer calls (\valid_function not supported)' "$$log"; \
		test $$rc -eq 0 && awk '$$1 == "[wp]" && $$2 == "Proved" && $$3 == "goals:" && $$4 > 0 && $$4 == $$6 { ok = 1 } END { exit !ok }' "$$log" && \
		! grep -Eq '(^|[[:space:]])(Timeout|Unknown|Failed):' "$$log"

indent:
ifeq ($(CLANG_FORMAT),)
	$(error clang-format 20 not found)
endif
	@$(CLANG_FORMAT) --version | grep -q 'version 20' || \
		{ echo "error: clang-format version 20 required"; exit 1; }
	$(CLANG_FORMAT) -i $(C_SOURCES)

clean:
	$(RM) solver mini gen_tables ida scan tables.h tables.s
	$(RM) -r build
