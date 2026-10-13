# Compositor — common tasks.
#
# `just` with no arguments lists every recipe.
# Builds land in ./build so they stay out of Xcode's shared DerivedData and are
# covered by .gitignore.

project := "Compositor.xcodeproj"
scheme  := "Compositor"
derived := "build"
app     := derived / "Build/Products/Debug/Compositor.app"

# The project signs with a "Mac Development" certificate, which a machine that only
# builds locally may not have. Ad-hoc signing lets these recipes work without one;
# scripts/release.sh still does the real Developer ID signing for a shipped build.
# CODE_SIGNING_ALLOWED stays on: turning it off skips the UI-test runner bundle entirely.
signing := "CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO"

default:
    @just --list

# Build a Debug build and launch it.
dev: build
    @echo "==> Launching Compositor"
    @open -n "{{app}}"

# Build Debug, without launching.
build:
    @echo "==> Building Compositor (Debug)"
    @xcodebuild build -quiet \
      -project "{{project}}" -scheme "{{scheme}}" -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}"

# Build Release, without launching. Unsigned — scripts/release.sh does the signed build.
build-release:
    @echo "==> Building Compositor (Release)"
    @xcodebuild build -quiet \
      -project "{{project}}" -scheme "{{scheme}}" -configuration Release \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" {{signing}}

# Run the unit tests. These are the suites that run unattended.
test:
    @echo "==> Testing Compositor"
    @xcodebuild test \
      -project "{{project}}" -scheme "{{scheme}}" -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" {{signing}} \
      -only-testing:CompositorTests

# These drive the real app, so Xcode Helper must be allowed under System Settings ›
# Privacy & Security › Accessibility; without it the runner is killed at startup with
# "Timed out while enabling automation mode".
#
# Run the XCUITest suite (needs a logged-in desktop plus Accessibility permission).
test-ui:
    @echo "==> Testing Compositor (UI)"
    @xcodebuild test \
      -project "{{project}}" -scheme "{{scheme}}" -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" {{signing}} \
      -only-testing:CompositorUITests

# Run every suite, UI tests included.
test-all:
    @xcodebuild test \
      -project "{{project}}" -scheme "{{scheme}}" -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" {{signing}}

# The local CI gate: clean warning-free build, then the unit tests. Runs before every push once `just hooks` is on.
ci:
    @./scripts/ci.sh

# Run the CI gate before every `git push` in this clone (skip one push with `git push --no-verify`).
hooks:
    @git config core.hooksPath .githooks
    @echo "==> pre-push now runs scripts/ci.sh"

# Run the unit tests under Address and Undefined Behavior Sanitizers (for the C pixel kernels); builds in build/sanitize.
test-sanitized:
    @./scripts/test-sanitized.sh

# Run one test target, e.g. `just test-only CompositorTests/BrushTests`.
test-only target:
    @xcodebuild test \
      -project "{{project}}" -scheme "{{scheme}}" -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath "{{derived}}" {{signing}} \
      -only-testing:"{{target}}"

# Resolve Swift package dependencies against Package.resolved.
resolve:
    @xcodebuild -resolvePackageDependencies -project "{{project}}"

# Update dependencies to the newest versions their ranges allow.
update:
    @xcodebuild -project "{{project}}" -scheme "{{scheme}}" \
      -onlyUsePackageVersionsFromResolvedFile=NO \
      -resolvePackageDependencies
    @git diff --stat -- Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Show the resolved version of every dependency.
deps:
    @cat Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Print the marketing version and build number.
version:
    @xcodebuild -project "{{project}}" -scheme "{{scheme}}" -configuration Release \
      -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ MARKETING_VERSION = | CURRENT_PROJECT_VERSION = /{print $1" = "$2}' \
      | sed 's/^ *//'

# Open the project in Xcode.
xcode:
    @open "{{project}}"

# Delete build output.
clean:
    @rm -rf "{{derived}}"
    @echo "==> Removed {{derived}}"

# Build, sign, notarize and package a DMG (see scripts/release.sh for what it needs).
release:
    @./scripts/release.sh

# Publish the DMG release.sh built, and the Sparkle appcast.
publish:
    @./scripts/publish.sh
