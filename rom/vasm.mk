# vasm for the ROM builds: the local vasmm68k_mot when present, otherwise
# the Docker image with the repository mounted at /work.
REPOROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
UNAME := $(shell uname)
DOCKERIMAGE := terriblefire78/vbcc:latest
DOCKERVASM = docker run --rm --platform linux/amd64 -v $(REPOROOT):/work -w /work/$(patsubst $(REPOROOT)/%,%,$(CURDIR)) $(DOCKERIMAGE)
AS = vasmm68k_mot

ifneq ($(UNAME), Linux)
	VASMENV = $(DOCKERVASM)
else
	VASM_LOCAL := $(shell which vasmm68k_mot 2>/dev/null)
	ifdef VASM_LOCAL
		VASMENV =
	else
		VASMENV = $(DOCKERVASM)
	endif
endif
