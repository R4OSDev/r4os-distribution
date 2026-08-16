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

Original R4OS material remains under Apache License 2.0. The matching
`R4OS-LICENSE.txt`, `R4OS-NOTICE.txt`, and aggregate
`THIRD-PARTY-NOTICES.txt` are shipped in every image and staged beside
binary release images.

## Root certificates

The system trust store contains public root certificates issued by DigiCert,
GlobalSign, and ISRG, plus the R4OS development root. The external certificate
identities are:

- DigiCert Global Root G2
- GlobalSign ECC Root CA - R4
- GlobalSign Root CA
- ISRG Root X1

The certificates are public trust anchors, not private keys. Consult each
certificate authority's repository and policy documents for current terms and
trust information.

## Test-only key material

`TestInjection/R4OS/CONFIG/TLS/R4TLSDEV.KEY` is an intentionally committed
test-only private key. It is public, provides no secrecy, and must never be
used for production, personal, or externally trusted systems.
