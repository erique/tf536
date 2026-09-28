.PHONY: version.inc
SHELL:=/bin/bash
BOARD:=tf536
REVISION:=2
GITVERSION:=`git rev-parse --short HEAD`
DATESTRING:=`date +"%Y-%m-%d"`

include vasm.mk

all: bootrom.v
version.inc:
	echo -ne "${BOARD}r$(REVISION)_$(DATESTRING)_$(GITVERSION)" > $@
bootrom.rom: version.inc
	$(VASMENV) $(AS) -cnop=0x0000 -Fbin -m68060 bootrom.asm -o $@
bootrom.v: bootrom.rom
	./bin2vrlg -f bootrom.rom > ../rtl/$@
clean:
	rm -rf *~ *.rom *.v
distclean: clean
	rm -rf \#*
