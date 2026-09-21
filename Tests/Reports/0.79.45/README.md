# 0.79.45 software package acceptance

2026-09-21, Debian/Linux, four CPUs, KVM, 1024 MB, no guest network.
Five actual release packages with 27 payloads were built and installed in the
existing technical image through SYSUPD STAGE/COMMIT, not direct file replacement.
The harness supplies current Kernel/SYSUPD/UPDSVC as the required active base.
Boot 0 verifies packages and stages the complete batch; boot 1 resumes it and
confirms release 0.79.45 plus software policy; boot 2 runs the installed Desktop
with the existing /SMOKE-WINDOW-IDLE scenario through normal poweroff. GUI
fixtures AppDefaults/MemView are supplied by the harness, not product payloads.

Standalone API/video/desktop VERIFY correctly returns 2 against old installed
R4NV/R4GFX. The first runner wrongly expected 0 and stopped after the successful
commit. Its restored backing image prevented reliable continuation of the
overlay. The corrected three-boot run passed all expected results. This was
an expectation correction, not a relaxation of package dependency validation.
Reboot/rollback fault coverage from 0.79.42/43 is reused, not repeated.

The supplied current platform is part of the final package set; this is not a
test of booting a kernel below its declared minimum. Such installations must
install platform and reboot first. Package installation preserves existing
service/startup configuration. No new permanent test group or Recovery image.
Complete inputs, private reproduction runner, package bytes/hashes and staged
file restoration proof: ExFiles/Reference/GFX/0.79.45/software-20260921.
The private runner assumes the existing Linux technical image and restores
all staged base files. Copy it to Temp/gfx-release07945 for a deliberate rerun
after preparing current packages and clearing the disposable run directory.

HostScope covers 54 shared build scripts syntactically. It is not Windows
execution. Native Windows and NVIDIA/receiver qualification remain open in
OssiGPU.txt. Scope and limits: Docs/Deployment/GrafikFreigabe07945.txt/.json.

The regular Full plan also passed: 110 inventory entries (109 modules plus
kernel); all 21 packaged component versions/targets match. No disk image was
built. SYSTEM remains 10240 MB and RECOVERY 5120 MB.
