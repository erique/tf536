SHELL:=/bin/bash
# X68000 CPLD boot ROM, and the boot chain and TFIDE loaded from the ATA
# card (README.md).
# IPL_FLAGS and TFIDE_FLAGS pass extra assembler options, e.g.
# TFIDE_FLAGS=-DTFIDE_TRACE.
include ../vasm.mk

BOARD:=tf536
REVISION:=2
GITVERSION:=`git rev-parse --short HEAD`
DATESTRING:=`date +"%Y-%m-%d"`

.PHONY: version.inc

all: ../../rtl/bootrom_x68k.v ata_devipl.bin ata_partipl.bin tfide.bin

# CPLD boot ROM at $EA8800, 128 bytes, as the Verilog ROM of x68k.v.
version.inc:
	echo -ne "${BOARD}r$(REVISION)_$(DATESTRING)_$(GITVERSION)" > $@
bootrom_x68k.rom: bootrom.asm version.inc x68k.i
	$(VASMENV) $(AS) -cnop=0x0000 -Fbin -m68060 bootrom.asm -o $@
../../rtl/bootrom_x68k.v: bootrom_x68k.rom
	../bin2vrlg -f bootrom_x68k.rom | sed 's/^module bootrom$$/module bootrom_x68k/' > $@

logo.bin: logo.ansi ansi2bin.py
	python3 ansi2bin.py logo.ansi $@
# Stage 1 must end within block 1 (stage1_end at or below $2400); the rest
# is the second stage in blocks 16-23 of slot 0.
ata_devipl.bin: ata_devipl.asm logo.bin x68k.i
	$(VASMENV) $(AS) -cnop=0x0000 -Fbin -m68000 -L ata_devipl.lst ata_devipl.asm -o $@
	@end=$$(awk '/^stage1_end /{print $$2}' ata_devipl.lst | sed 's/.*://'); \
	echo "ata_devipl.bin $$(wc -c < $@) bytes, stage 1 ends at $$end"; \
	if [ $$((16#$$end)) -gt $$((16#2400)) ]; then echo "ERROR: stage 1 exceeds block 1" >&2; rm -f $@; exit 1; fi
# Everything the partition IPL needs before it loads its second half must
# lie in the first 1024 bytes (first_half_end at or below $2800).
ata_partipl.bin: ata_partipl.asm scc.i x68k.i
	$(VASMENV) $(AS) -cnop=0x0000 -Fbin -m68000 $(IPL_FLAGS) -L ata_partipl.lst ata_partipl.asm -o $@
	@end=$$(awk '/^first_half_end /{print $$2}' ata_partipl.lst | sed 's/.*://'); \
	echo "ata_partipl.bin first half ends at $$end"; \
	if [ $$((16#$$end)) -gt $$((16#2800)) ]; then echo "ERROR: partition IPL first half exceeds 1024 bytes" >&2; rm -f $@; exit 1; fi
tfide.bin: tfide.asm scc.i x68k.i
	$(VASMENV) $(AS) -cnop=0x0000 -Fbin -m68000 $(TFIDE_FLAGS) tfide.asm -o $@
clean:
	rm -f *.bin *.lst *.rom
