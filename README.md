# R4OS Distribution

This repository assembles independently built R4OS components into Slim, Full,
Test, and explicit Benchmark disk images. It owns image profiles, versioned injection data,
host-side image tools, QEMU configuration, and integration checks. It does not
rebuild the kernel, libraries, or modules.

## Commands

    Build.bat test
    Build.bat plan Slim
    Build.bat image Full
    Build.bat verify Full
    Build.bat qemu Full
    Build.bat qemu Full RTL8139
    Build.bat ssh Full
    Build.bat headless Test
    Build.bat headless Test clock4
    Build.bat image Test browser
    Build.bat headless Test browser
    Build.bat image Benchmark
    Build.bat benchmark Benchmark perfdiag-clock 0.3.7 warm 5 r4os-q35-haswell-smp4-1g-tcg-gpt1-v1

On Linux, use the same arguments with `./Build.sh`; tools, tests, plan
generation, image creation, verification, GUI/headless QEMU, and benchmarks
are equivalent host entry points. `Settings.R4S` maps input artifacts and
DevKit tools with portable relative defaults.

`ssh Full` starts an existing Full image without a display and forwards only
`127.0.0.1:10022` to the guest's `10.0.2.15:22`. It keeps the profile data
image persistent, writes serial output to
`Artifacts/Distribution/Logs/qemu-ssh-debug.log`, and stays in the foreground
until the guest powers off. Connect with
`ssh -p 10022 -c chacha20-poly1305@openssh.com r4os@127.0.0.1`. Normal GUI
and SSH launches use host acceleration when available and select VirtioNet by
default. Passing `RTL8139` after the profile selects the explicit compatibility
adapter. Both provide the same loopback-only SSH path; automated headless tests
and benchmarks remain network-disabled, and the versioned benchmark environment
stays fixed to single-threaded TCG/Haswell.

The optional `browser` variant layers `BrowserTestInjection` over the normal
Test injection and evaluates the additional offline Klickifax markers. The
workspace command `-testbrowser` creates the matching component plan; regular
Test images and marker runs omit the browser bundle. Regular headless
acceptance uses four vCPUs and a 1200-second default timeout. This bound
includes the concurrent 60-guest-second R4GB and R4SNES product runs;
`QEMU_TEST_TIMEOUT_SECONDS` overrides it explicitly.
The `clock4` variant is a short four-vCPU smoke test: it validates boot, SMP,
parallel progress, generation-bound TLB shootdowns with safe Ack-timeout
rollback, sharded runtime/owner locks under short four-CPU heap stress, the
loss-free COM1 bulk path, one read-only NVMe-sector completion through MSI or
single-vector MSI-X, and the cross-CPU monotonic clock/IRQ proof. QEMU stops as
soon as the final `[QUICKPROBE] result=DONE` marker confirms both bounded probe
groups. It therefore does not start userland, R4GB, or R4SNES.
The standard QEMU configuration keeps the boot volume on ICH9 AHCI and attaches the
fresh data image as an NVMe namespace. The existing 1-MB FSDIAG guest probe and
required ownership/mount markers therefore cover canonical NVME.R4D discovery
and data-volume I/O on every normal headless acceptance run.
Both standard and browser acceptance run `REG APITEST`, `REG MIGRATESELFTEST`,
and `REGEDIT /SELFTEST`. Required markers cover stable bounded snapshot pages,
explicit generation restart, a 32-operation atomic batch, validation and
commit aborts without partial visibility, batched R4S migration, and the real
REGEDIT snapshot model. REGEDIT remains a Full module and is added to Test only
as an explicit integration-test include. Legacy single-value operations remain
covered.

Building the Benchmark profile never starts a benchmark. The `benchmark`
action is the only measured path: it requires a complete request, creates a
fresh run data image, uses the versioned fixed QEMU environment, requires a
complete PERFDIAG machine block and regular guest poweroff, and writes the
current machine-readable result below the Benchmark profile. Normal builds,
tests, headless acceptance, and GUI runs never invoke it.

The result uses `r4os.benchmark.run` schema 2 and binds a unique run ID,
release and benchmark-image SHA-256 to the validated request and machine
records. `Tools/BenchmarkHistory.ps1` validates and atomically imports only
catalogued trend metrics into the workspace-local
`ExFiles/Reports/Benchmarks.jsonl`, validates the JSONL history, and compares
only identical suite/workload/environment/metric series. It is never invoked
automatically by image creation, tests, or QEMU startup. The complete operator
contract is `Agents/Benchmark.txt` in the workspace root.

The time-bounded blit suite intentionally varies iterations and total bytes
between samples. Its importer derives and validates a stable frame size from
`bytes / iterations`, then combines it with the fixed 250 ms window for the
workload identity.

Every generated image contains legal material under
`/R4OS/LICENSES`. The same payload is staged in the profile's
`Legal` directory beside `disk.img` for binary releases.

Detailed German migration notes are preserved in
`DOCUMENTATION.de.txt`.

## Releases

Build the required profile images before preparing a release. `Standard`
packages Slim and Full; `All` additionally packages Test. Use `Release.bat`
on Windows or `./Release.sh` on Linux with the same arguments:

    <release-starter> selftest
    <release-starter> prepare Standard
    <release-starter> publish Standard
    <release-starter> publish Standard -prerelease

`prepare` verifies every selected image and its legal payload, creates a ZIP
per profile, calculates SHA-256 checksums, and records the exact repository
commits and tool versions in a source manifest. Output is written below
`Artifacts/Distribution/Releases/<version>/` in the mapped workspace.

Each package contains one `disk.img` with BIOSBOOT/BOOT/SYSTEM/RECOVERY/DATA,
fresh DATA, the exact independent `recovery.zip`, USB creation starters,
QEMU configuration, legal files, and a manifest with all file hashes.
`RecoveryPin.json` selects a published Recovery version and SHA256. An explicit
`-TechnicalCandidate -RecoveryCandidate <ZIP>` passed to `Tools/Release.ps1`
allows local acceptance packages; publication rejects that mode.
GUI/SSH use persistent image copies keyed by the source SHA256; automated
runners start from fresh copies. Release images contain no original-ZIP cache.

`publish` performs the same preparation, creates a draft release in
`R4OSDev/r4os-distribution`, uploads every asset, and only then publishes the
release. An interrupted upload remains a draft. It uses the workspace
credential file created by `Tools/Setup.bat` or `./Tools/Setup.sh` and requires
GitHub Contents write permission.

## License

Original R4OS material is licensed under Apache License 2.0. Third-party
components retain their own licenses; see `THIRD_PARTY_NOTICES.md`.


NTFS image boundaries (0.78.73)
-------------------------------
The shared R4OS path policy is 24 components, including a final file name.
The builder checks a child's depth before insertion. ImageCreator counts
the complete destination before creating parent nodes. NtfsVerify applies
the same boundary to both files and directories. The public volume reader
uses that shared constant; its existing runtime limit is unchanged.

The builder's index bitmap now covers all 4096 permitted index blocks.
Block construction checks the same limit before allocation; resident record
capacity remains checked by prepare, before any target is opened for writing.
A 3500-file fixture needs 587 blocks and an 80-byte bitmap, including the
previously out-of-range bit 512. Verification and the final long-name lookup
both succeed.

NtfsVerify collects consecutive nonresident extents, checks physical run
ranges and logical coverage, and requires initialized size <= data size.
Ordinary attributes require data size <= allocated size and complete run
coverage of that allocation, without holes. Sparse/compressed streams and
the special $BadClus:$Bad stream are distinguished; their logical coverage
is checked without applying ordinary physical-allocation equality. Raw
readRunsInto supports sparse zeroes but rejects compressed/encrypted data,
and never reports bytes beyond its actual run array as read successfully.
This does not claim to validate decompressed or decrypted file contents.

Reference: Microsoft ATTRIBUTE_RECORD_HEADER
https://learn.microsoft.com/en-us/windows/win32/devnotes/attribute-record-header
and the existing local NTFS layout references.

## Explicit virtual graphics check

`Build.bat graphics-test Test` / `./Build.sh graphics-test Test` runs the short
native, injected-timeout and absent-device variants sequentially. Append
`native`, `timeout`, `fallback` or `probe` to select one. It requires current
Test artifacts plus explicitly built VIRTGPU.R4D; it does not rebuild modules
or run the ordinary long test suite. The Virtio driver stays IMAGE_SCOPE=none.

`QEMU/virtio-gpu.conf` adds the explicit VGA-compatible 2D device to the shared
standard machine. Every guest has four vCPUs, no network and a 90-second limit.
Native validation checks 32 sparse images, two QMP pixel captures, stable BO
ownership and two VNC resize notifications while the guest is not drawing.
VNC binds only loopback. Timeout validation requires acknowledged reset,
bootfb restoration and resource release. The fallback variant uses standard
VGA with exactly the same R4D/Kernel/diagnostic binaries. Virtio completion
is device execution; no VBlank or physical NVIDIA/HDMI result is implied.

Generated CONFIG/AUTOEXEC/catalog/PPM/log/result files live under
`Temp/gfx-virtio/<variant>` in the mapped workspace. Versioned injections are
never rewritten. Fresh source/run media live below the configured distribution
output's `Technical/virtio-gpu-<variant>`. Ordinary build/test entry points do
not invoke this explicit profile.

`graphics-test Test nvidia-passive` reuses the existing short graphics harness
for the passive NVIDIA driver on ordinary VGA. It requires built NVIDIA and
DISPLAYD artifacts, creates a separate Test image with the canonical module
inventory, and checks failed-load cleanup, driver records and usable bootfb
with four vCPUs and no guest network. The default `all` selection continues
to run the three Virtio cases. No NVIDIA hardware behavior is emulated by
the absence case, and normal profiles do not include NVIDIA.R4D.
