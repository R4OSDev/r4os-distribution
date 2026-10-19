R4OS early CPU firmware, source0.85.33
====================================

Manifest.json binds the original complete vendor binaries, source commits,
byte lengths, SHA256 hashes and initial exact CPU load profiles. They are
data owned by Distribution, not executable R4M0 modules or a public register
interface. Required notices are installed under R4OS/LICENSES; the original
AMD patch list and base-revision requirements accompany the firmware.

Tools/CpuMicrocode.ps1 validates the files before building a bounded R4U0
appendix. The preload tool appends it after the original R4I total. The
R4I header, all nine entries and module payloads retain their exact bytes;
older kernels continue to parse the original prefix. A legacy image without
the appendix means optional firmware missing. No new Limine module, boot
configuration, Recovery image or installed module-catalogue entry is needed.

R4U0 has a32-byte version1 header (magic, u16 version/header bytes, u32 count,
total, entry size, twelve zero reserved bytes). Two64-byte entries bind vendor,
profile id, contiguous payload offset/length, CPUID signature, target/minimum
revision, Intel platform mask and32-byte original-file SHA256. Complete
original vendor files follow. The kernel independently anchors all these
identities and validates both vendor formats before a load. Replacing a
firmware pin therefore also needs a reviewed/versioned kernel catalogue.

Initial Intel profile: CPUID0x306c3, actual platform in mask0x32, revision0x28.
Initial AMD profile: CPUID0x00a00f11 (Milan B1), target0x0a0011de, minimum
current revision0x0a0011d9. The older0x0a0011d5 fallback present in the original
AMD container is not selected to bypass the vendor's signing prerequisite.
Other family19h patches remain original data; inclusion is not load approval.

Only initial local BSP/AP entry may submit an exact validated native patch,
before final CPU/PAT/FPU admission. Logical restart never loads an update
while consumers exist. It rereads/requalifies and rejects a required reload.
Virtual machines expose virtual status and never submit a hardware update.
Absent or rejected optional firmware is recorded and never submitted; normal
CPU/PAT/FPU qualification still decides admission on the actual BIOS state.
This keeps durable boot recovery reachable when an interrupted update leaves
an older/newer optional preload. An attempted load with a refused/mismatching
readback remains terminal for that CPU, as does a required runtime reload.
Supplied data, source/synthetic tests and a VM boot do not prove a successful
physical update. Host orchestration supports PowerShell7 on Windows/Linux.
