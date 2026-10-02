# Security

Polycop runs locally. It reaches the network only to download models from the
catalog, each verified by size and SHA-256 before use, and to read the latest
release from GitHub, when the user asks or once a day if they allow it. Both
requests carry the app's name and no cookie, not the Mac's version or
languages.

Releases are built by the repository's workflow, which can only read the
code, and attested by GitHub: `gh attestation verify Polycop-X.Y.Z.dmg --repo
miravassor/polycop` names the commit and the run that built a file. Published
releases cannot be changed. The app keeps macOS's hardened runtime; only
library validation is lifted, because ad hoc signed code carries no team
identifier.

Please report a vulnerability privately, through GitHub's
[security advisories](https://github.com/miravassor/polycop/security/advisories/new)
or by email to polycopproject@proton.me, rather than in a public issue.
Include the version, the macOS version and the steps to reproduce.
