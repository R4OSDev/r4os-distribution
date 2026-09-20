# 0.79.43 SMP4 integration record

Three accepted bounded, offline scenarios on an existing technical image:
bootfb with EXAMPLE gfx-queue-test; Virtio native plus host resize; Virtio timeout.
All reach normal poweroff with four online CPUs. The first bootfb preparation
omitted the required key and used paths outside the update inbox. It was fixed
and rerun once. Its successful rerun needed only an offline expectation fix:
SYSUPD rejects malformed component metadata with code 1 (code 2 is for a
requirement conflict). Its actual six command results were revalidated without
another guest run. No failed product probe is being treated as passed.

Reproduce using the existing Tools/Test-VirtioGpu.ps1 native/timeout scenarios,
or copy workspace ExFiles/Reference/GFX/0.79.43/software-20260921/Guest.ps1 back
to Temp/gfx-stability07943/Guest.ps1 and invoke pwsh -NoProfile -File ... -Variant
bootfb, native, or timeout. The private runner requires the existing Linux
Technical/gfx-gl-product-window07939/disk.img and refuses occupied evidence
directories. It restores every staged base file and verifies original hashes.
Guest AUTOEXEC/configuration and input hashes are in the external evidence.
It uses the common Distribution QEMU host profile and four CPUs, no network,
a 120-second bound and small qcow2 overlays. For bootfb it sends g through QMP
on the existing waiting-for-IRQ marker. Native uses the existing RFB resize and
pixel checker. This is a one-off release record, not a new recurring gate.

The software report lists artifact hashes, error injection, resource scope and
physical followup. See workspace Docs/Deployment/GrafikStabilitaet07943.txt.
