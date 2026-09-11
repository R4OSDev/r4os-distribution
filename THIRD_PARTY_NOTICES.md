# Third-Party Notices

The Distribution repository assembles R4OS images from independently built
artifacts. Its versioned image overlay includes the complete license payload
under `Injection/R4OS/LICENSES`.

## Material shipped in an R4OS image

| Component | License or status | Image license file |
| --- | --- | --- |
| Limine 12.0.1 bootloader binaries | BSD-2-Clause | `Limine-BSD-2-Clause.txt` |
| FreeType 2.14.3 | FreeType License 1.0 | `FreeType-FTL.txt` |
| Google Brotli 1.2.0 | MIT | `Brotli-MIT.txt` |
| zlib 1.3.1 | zlib License | `zlib.txt` |
| stb_image 2.30 | MIT selected from its dual offer | `stb_image-MIT.txt` |
| RTL8168 firmware tables derived from the Realtek vendor driver | GPL-2.0-only | `RTL8168-GPL-2.0-only.txt` |
| libdisplay-info timing data and EDID fixtures | MIT | `libdisplay-info-MIT.txt` |
| Original NVIDIA GSP 570.144 containers in explicitly selected NVIDIA.R4D | NVIDIA's original license; not Apache-2.0 | `NVIDIA-570.144-LICENSE.txt` |
| NVIDIA 570.144 production GSP boot artifacts and derived WPR/layout/init preparation | Original MIT notices and package COPYING | `NVIDIA-570.144-GSP-BOOT-LICENSE.txt` |

Original R4OS material remains under Apache License 2.0. The matching
`R4OS-LICENSE.txt`, `R4OS-NOTICE.txt`, and aggregate
`THIRD-PARTY-NOTICES.txt` are shipped in every image and staged beside
binary release images.

NVIDIA.R4D has `IMAGE_SCOPE=none` and is absent from ordinary images. An
explicit selection carries both original GSP containers and the complete
unmodified NVIDIA license as module resources. The source owner records
exact origin, version, lengths and SHA-256 values in `src/firmware-lock.json`.
The shared license overlay preserves the same complete license text beside
the image and under `/R4OS/LICENSES`; it does not enable the driver or imply
hardware support. Original proprietary firmware is not relicensed or altered.

NVIDIA.R4D 0.1.24 carries the unchanged production GA102 boot
image/descriptor and complete notices for their generated source and the
MIT-derived WPR metadata/layout and Libos/RM/queue initialization code.
The central pin binds all twelve source/notice inputs and artifact hashes;
the same full notices accompany the image and module. Boot resource staging
does not establish firmware execution, display ownership or HDMI audio.

## Root certificates

The system trust store contains public root certificates issued by DigiCert,
GlobalSign, ISRG, and Sectigo, plus the R4OS development root. The external certificate
identities are:

- DigiCert Global Root G2
- GlobalSign ECC Root CA - R4
- GlobalSign Root CA
- ISRG Root X1
- USERTrust RSA Certification Authority (Sectigo): DER SHA-256
  `e793c9b02fd8aa13e21c31228accb08119643b749c898964b1746d46c3d4cbd2`.
  Obtained from the [issuer repository](http://crt.sectigo.com/USERTrustRSACertificationAuthority.crt)
  on 2026-09-05 and matched byte-for-byte against the Debian/Mozilla root.
- USERTrust ECC Certification Authority (Sectigo): DER SHA-256
  `4ff460d54b9c86dabfbcfc5712e0400d2bed3fbc4d4fbdaa86e06adcd2a9ad7a`.
  Obtained from the [issuer repository](http://crt.sectigo.com/USERTrustECCCertificationAuthority.crt)
  on 2026-09-05 and matched byte-for-byte against the Debian/Mozilla root.

The GitHub API chains observed on 2026-09-05 ended in these USERTrust
cross-signatures for RSA and ECDSA respectively. The actual R4TLS guest
handshake selected ECDSA. See the
[issuer's explanation of cross-signing](https://www.sectigo.com/knowledge-base/detail/Sectigo-Root-Certificates).

The certificates are public trust anchors, not private keys. Consult each
certificate authority's repository and policy documents for current terms and
trust information.

## Test-only key material

`TestInjection/R4OS/CONFIG/TLS/R4TLSDEV.KEY` is an intentionally committed
test-only private key. It is public, provides no secrecy, and must never be
used for production, personal, or externally trusted systems.

NVIDIA 570.144 PRAMIN / VGA-workspace capture (NVIDIA.R4D 0.1.29)
File: NVIDIA-570.144-PRAMIN-LICENSE.txt
The attributed GM107 window access and VGA-workspace geometry follow the
pinned NVIDIA 570.144 source. All five complete per-source MIT notices and
copyright lines are included identically in the module and image overlay.
R4OS snapshot ownership, SDK bindings and failure handling are Apache-2.0.
The explicit boot-check may select and restore the CPU BAR0/PRAMIN window;
it does not execute firmware, relocate VGA or initialize native scanout.

NVIDIA 570.144 BAR1 / GMMU boot mapping (NVIDIA.R4D 0.1.34)
File: NVIDIA-570.144-BAR1-LICENSE.txt
The linked bounded BAR1 resolver and physical-function register reader adapt
MIT definitions from the pinned NVIDIA source. Complete original notices
are included in this file and in the nonallocated driver resource. Existing
PRAMIN and firmware notices still apply. The boot-check preserves full boot
mapping dependency pages; it does not start firmware or program scanout.

NVIDIA boot display observation (NVIDIA.R4D 0.1.35)
File: NVIDIA-BOOT-DISPLAY-LICENSE.txt
Armed display-state mirror/topology reads adapt Nouveau GA102/GV100 MIT
sources; field meanings follow NVIDIA 570.144 C67D under MIT. Full original
copyright and permission notices accompany the driver and this directory.
The read-only boot capture provides programmed timings and routing; native
console modesetting, visible completion and full recovery remain separate.
