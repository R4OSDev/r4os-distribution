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
    Build.bat ssh Full
    Build.bat headless Test
    Build.bat image Test browser
    Build.bat headless Test browser
    Build.bat image Benchmark
    Build.bat benchmark Benchmark perfdiag-clock 0.3.7 warm 5 r4os-q35-haswell-1vcpu-1g-tcg-v1

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
launches provide the same local RTL8139/SSH path; automated headless tests and
benchmarks remain network-disabled.

The optional `browser` variant layers `BrowserTestInjection` over the normal
Test injection and evaluates the additional offline Klickifax markers. The
workspace command `-testbrowser` creates the matching component plan; regular
Test images and marker runs omit the browser bundle. Headless acceptance uses
a 240-second default timeout for the standard variant and 360 seconds for the
larger browser variant; `QEMU_TEST_TIMEOUT_SECONDS` overrides either default.

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

Every generated image contains legal material under
`/R4OS/LICENSES`. The same payload is staged in the profile's
`Legal` directory beside `disk.img` for binary releases.

Detailed German migration notes are preserved in
`DOCUMENTATION.de.txt`.

## Releases

Build the required profile images before preparing a release. `Standard`
packages Slim and Full; `All` additionally packages Test.

    Release.bat selftest
    Release.bat prepare Standard
    Release.bat publish Standard
    Release.bat publish Standard -prerelease

`prepare` verifies every selected image and its legal payload, creates a ZIP
per profile, calculates SHA-256 checksums, and records the exact repository
commits and tool versions in a source manifest. Output is written below
`Artifacts/Distribution/Releases/<version>/` in the mapped workspace.

Each package contains `disk.img`, a newly generated empty `data.img`, the
QEMU configuration, legal files, and an image manifest. The persistent
profile data image from the developer workspace is never published.

`publish` performs the same preparation, creates a draft release in
`R4OSDev/r4os-distribution`, uploads every asset, and only then publishes the
release. An interrupted upload remains a draft. It uses the workspace
credential file created by `Tools/Setup.bat` and requires GitHub Contents
write permission.

## License

Original R4OS material is licensed under Apache License 2.0. Third-party
components retain their own licenses; see `THIRD_PARTY_NOTICES.md`.
