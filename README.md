# R4OS Distribution

This repository assembles independently built R4OS components into Slim, Full,
and Test disk images. It owns image profiles, versioned injection data,
host-side image tools, QEMU configuration, and integration checks. It does not
rebuild the kernel, libraries, or modules.

## Commands

    Build.bat test
    Build.bat plan Slim
    Build.bat image Full
    Build.bat verify Full
    Build.bat qemu Full
    Build.bat headless Test

The equivalent host-neutral tool and plan checks are available through
`./Build.sh`. `Settings.R4S` maps input artifacts and DevKit tools.

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
