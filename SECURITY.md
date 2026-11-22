# Security

Polycop runs locally. It reaches the network only to download models from the
catalog, each verified by size and SHA-256 before use, and to read the latest
release from GitHub, when the user asks or once a day if they allow it. Both
requests carry the app's name and no cookie, not the Mac's version or
languages.

Releases are built by the repository's workflow, which can only read the
code, and attested by GitHub:

    gh attestation verify Polycop-X.Y.Z.dmg --repo miravassor/polycop \
        --signer-workflow miravassor/polycop/.github/workflows/release.yml

names the commit and the run that built a file. Releases published from 0.4.0
on cannot be changed. The app keeps macOS's hardened runtime; only
library validation is lifted, because ad hoc signed code carries no team
identifier.

## Threat model

### Assets

* The user's transcripts, corrections and glossaries in
  `~/Library/Application Support/Polycop/` (`History/`, `Glossaries/` and
  `Snapshots/`, created mode `0700`).
* Recordings, which often hold someone else's words. They stay where the user
  keeps them and are never copied into the library.
* The rest of the user's files: Polycop is not sandboxed, so it runs with the
  user's account permissions.
* The integrity of model weights and published releases.

### Trust boundaries and guards

* **Network:** Only `ModelDownloader` and `UpdateCheck` open a `URLSession`.
  Model downloads fetch pinned commits in `ModelCatalog`, abort if the stream
  exceeds the expected size, and pass SHA-256 verification before installation
  and size and SHA-256 verification before every native load. Release checks
  query GitHub by numeric repository ID and accept only an `https://github.com`
  release tag URL. Both use ephemeral sessions with fixed `User-Agent: Polycop`
  and `Accept-Language: en` headers and no cookies. The bundled `ffmpeg`
  helper is built with `--disable-network` and invoked with
  `-protocol_whitelist file,pipe`.
* **Native C and C++ engines (`whisper.cpp`, `audio.cpp`):** Only catalog model
  weights that pass size and SHA-256 verification reach the native parsers
  (`ModelStore.install` on import, `ModelStore.verify` before every load). Any
  `.bin` or `.gguf` file not in the catalog placed in the models folder by hand
  is listed as unverified so the user can delete it, and is never loaded. The
  bundled Silero VAD weights ship inside the app bundle and are checked against
  their pinned SHA-256 in `ModelTests`. Recordings reach the engines only as
  decoded 16 kHz mono PCM floats, capped at four hours. In the build,
  `audio.cpp` and `ffmpeg` compile from pinned sources (Git commit for
  `audio.cpp` with its network model manager disabled; tarball SHA-256 and the
  FFmpeg release signing key for `ffmpeg`), while `whisper.cpp` is consumed as
  upstream's prebuilt binary XCFramework pinned by SHA-256 checksum in
  `Packages/WhisperFramework/Package.swift`.
* **Media and document inputs:** Recordings are decoded by the bundled `ffmpeg`
  helper process (not sandboxed, built with `--disable-everything` and only the
  needed audio codecs, with its diagnostic log capped at 4 MB) and played by
  `AVFoundation`. Imported transcripts are parsed in Swift (`TranscriptImport`)
  with a 5 MB file and text limit, a 50,000-cue limit and monotonic timestamp
  checks within four hours; `.docx` imports use `NSAttributedString` with an
  explicit `.officeOpenXML` document type. Glossary documents (`Documents`)
  enforce file, page and text limits (50 MB file, 2,000 PDF pages, 5 MB for
  plain text, RTF or Word sources and for extracted text) and are read through
  `PDFKit` and `NSAttributedString` with explicit `.rtf` or `.officeOpenXML`
  document types, refusing HTML sniffing.
* **Logging:** `Log` writes diagnostics only to the local macOS unified log.
  No transcript text is logged, and user file paths and engine or decoder error
  details are marked private so the system redacts them.

### Out of scope

* Local attackers or malware running under the same macOS user account.
* Encryption at rest for transcripts, glossaries or recordings: macOS user
  accounts and FileVault cover those.

## Reporting

Please report a vulnerability privately, through GitHub's
[security advisories](https://github.com/miravassor/polycop/security/advisories/new)
or by email to polycopproject@proton.me, rather than in a public issue.
Include the version, the macOS version and the steps to reproduce.
