# Contributing to Compositor

Thanks for helping. This page covers how to build and test a change and what it needs to be merged.

## Setting up

- macOS 26.5 or later and Xcode 26.5 or later.
- [`just`](https://github.com/casey/just) (`brew install just`) for the commands below; each recipe is a thin
  wrapper around `xcodebuild` or a script in `scripts/`, so you can run those directly instead.
- Once per clone, `just hooks`: the CI gate then runs before every `git push`.

`just dev` builds a Debug build and launches it, or open `Compositor.xcodeproj` and run the shared
**Compositor** scheme. Builds from `just` land in `build/`, which git ignores.

## Testing

- `just ci` is the gate every change must pass: a clean build of the app and test targets in which **any
  compiler warning is an error**, followed by the unit tests. It is `scripts/ci.sh`, the same script the CI
  workflow runs on GitHub for every push to `main` and every pull request, so passing locally means passing
  there.
- `just test` runs the unit tests alone; `just test-only CompositorTests/BrushTests` runs one suite.
- `just test-sanitized` runs the unit tests under Address and Undefined Behavior Sanitizers. Run it when you
  touch the C pixel kernels in `Compositor/Rendering/*.c`; the Sanitizers workflow also runs it on such pull
  requests and weekly.
- `just test-ui` runs the XCUITest suites, which drive the real app and need a logged-in desktop with Xcode
  Helper allowed under System Settings › Privacy & Security › Accessibility. They are not part of the gate.

New tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`,
`#expect`, `#require`), like the existing suites in `Tests/CompositorTests/`. A bug fix comes with a test that
fails without it. A change to what a project saves comes with a round-trip test and an update to
`docs/project-format.md`: new fields are optional, and anything older builds would misread raises the
format version.

## Style

Match the code around your change: its naming, its comment voice (comments say why, in plain sentences), and
its layout. Indentation is four spaces in Swift, C and shell; `.editorconfig` sets this up for most editors.
The project builds in the Swift 6 language mode with strict concurrency checking, so keep main-actor and
`Sendable` boundaries explicit rather than silencing diagnostics. Keep pixel loops that need speed in the C
kernels, with their bounds checked by the Swift caller and exercised by tests.

Work that takes more than a frame runs off the main actor, and checks on its way back that the document it
read is still the one on screen; when that check drops a result, log it rather than dropping it silently. Log
through `Logger.compositor("<Area>")` (`Compositor/IO/AppLog.swift`), so every line shares one subsystem.
Don't swallow errors a user would want to know about with `try?`: report them in the UI, or log them where
nobody is waiting on the result.

## Pull requests

- Keep each pull request to one change, and describe what it changes for someone using the app.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.
- Update `README.md` when you add or remove a feature.
- Third-party dependencies are added only with a good reason; Sparkle is currently the only one. Pin it in
  `Package.resolved` and say why in the pull request.
- Report security problems privately, as [SECURITY.md](SECURITY.md) describes, not in a pull request.
