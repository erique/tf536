# TF536 X68000: several virtual disks on one ATA card

The card follows SCSI2SD, which carries several SCSI targets on one SD card
and keeps where each target starts and how long it is in the board's
configuration flash. The TF536 has no such store in its firmware, so the card
carries that information itself: each virtual disk ("slot") is an SxSI disk
image, and the free tail of its header block, which the SxSI layout leaves
unused, links it to the next slot. A SCSI2SD card converts directly, one slot
per enabled target.

The CPLD boot ROM loads the device
IPL from slot 0; the device IPL shows a boot menu across all slots and hands
the chosen partition to its partition IPL; TFIDE registers every usable
partition of every slot as a Human68k drive, the booted one as C:. A card
may also carry one data region after the last slot, an opaque image for a
guest other than Human68k.

## Building a card

    make -C rom/x68k
    rom/x68k/card.py build -o card.img disk0.hda disk1.hda
    rom/x68k/card.py build -o card.img --scsi2sd config.xml card.ima
    rom/x68k/card.py build -o card.img disk0.hda --data amiga.hdf
    dd if=card.img of=/dev/sdX bs=1M conv=fsync
    rom/x68k/card.py check card.img disk0.hda disk1.hda --data amiga.hdf

`card.py build --overlay-only` updates the firmware on an existing card
without touching partitions or the data region. `card.py check` also reads a
card dumped back with `dd`.

A single `.hda` gives a single-slot card; so does a raw `.hda` written with
`dd`. The card and the CPLD boot ROM go together: a card whose block 1 holds
SxSI's own device IPL does not boot from the CPLD. With no card the boot ROM
returns to the IPLROM.
