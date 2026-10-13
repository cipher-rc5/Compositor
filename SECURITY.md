# Security policy

Compositor opens files that come from anywhere: Photoshop documents, camera RAW files, ordinary images and
`.comp` projects shared by other people. A crafted file that crashes the app, corrupts memory, reads or
writes outside what the user chose, or makes the app misbehave is a security bug, and reports are welcome.

## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/cipher-rc5/Compositor/security/advisories/new)
(the repository's **Security** tab › **Advisories** › **Report a vulnerability**).

Please do not open a public issue, pull request or discussion for a suspected vulnerability until it has
been fixed. Include what you can of:

- the Compositor version (Compositor › About Compositor) or commit, and the macOS version;
- the file that triggers it, or how to make one (attach it to the advisory; it stays private);
- what happens (crash log, sanitizer report, or the unexpected behavior) and what you expected.

You can expect an acknowledgement within a week, and to be kept informed while a fix is prepared. Fixes are
released as a new version through the app's automatic updates, and the advisory is published with credit to
you unless you prefer otherwise.

## Supported versions

Only the latest release, and `main`, receive security fixes. Compositor updates itself, so the fix for a
supported problem is to update to the newest version.

## Scope

In scope:

- **File parsing**: the PSD reader (`Compositor/IO/PSD/`), the `.comp` project loader and its validation
  (`Compositor/IO/ProjectStore.swift`, described in `docs/project-format.md`), RAW import
  (`Compositor/IO/RawImporter.swift`), and image import, paste and drag and drop.
- **The C pixel kernels** in `Compositor/Rendering/*.c`, which index image buffers directly: out-of-bounds
  access, integer overflow in size or offset arithmetic, and similar memory-safety bugs.
- **Updates and releases**: the Sparkle update feed and signature checks as the app configures them
  (`Config/Info.plist`), and the release scripts (`scripts/release.sh`, `scripts/publish.sh`) and CI
  workflows (`.github/workflows/`).
- Anything that lets a document escape the app sandbox's limits on the files it may read or write.

Out of scope:

- Bugs in Apple's frameworks (ImageIO, Core Image's RAW decoding, AppKit) or in Sparkle itself; please report
  those to Apple or to [Sparkle](https://github.com/sparkle-project/Sparkle/security). If Compositor could
  reasonably defend against one, that part is in scope.
- Running out of memory or time on a legitimately enormous file within the documented limits (30,000 pixels
  per side, 100 million pixels; see `docs/project-format.md`).
- Attacks that need an attacker who already controls the user's account or Mac.
- Releases of the upstream project, [robbietilton/Compositor](https://github.com/robbietilton/Compositor),
  which this repository's builds update from; report problems in those to that repository.

## Hardening already in place

The app runs in the App Sandbox with the hardened runtime and reaches only files the user selects. Releases
are signed with a Developer ID, notarized, and published with a SHA-256 checksum and a bill of materials;
updates are verified against the app's Sparkle EdDSA key before they install. Projects are validated before
they replace the open document (see `docs/project-format.md`), and the unit tests run under Address and
Undefined Behavior Sanitizers weekly (`just test-sanitized`).
