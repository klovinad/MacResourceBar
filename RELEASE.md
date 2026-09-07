# Release process

MacResourceBar 1.2 (build 6) uses one version source in the Xcode project. The Release build is always produced for both Apple silicon and Intel.

## Local package

Run:

```bash
./script/package_dmg.sh
```

Without a Developer ID identity this creates an explicitly local, ad-hoc signed package at `Release/MacResourceBar-1.2-local.dmg`. Do not publish that artifact. The suffix is deliberately different from the public artifact name.

## Public package

Public packaging is fail-closed: both a Developer ID Application identity and notarization credentials are required.

Set the signing identity exactly as it appears in Keychain Access:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example Name (TEAMID)'
export RELEASE_MODE=public
```

Configure one notarization method.

### Keychain profile

Create the profile once:

```bash
xcrun notarytool store-credentials MacResourceBar-notary \
  --apple-id 'developer@example.com' \
  --team-id 'TEAMID' \
  --password 'app-specific-password'
```

Then export:

```bash
export NOTARYTOOL_PROFILE=MacResourceBar-notary
```

### App Store Connect API key

```bash
export APP_STORE_CONNECT_KEY_FILE='/absolute/path/to/AuthKey_KEYID.p8'
export APP_STORE_CONNECT_KEY_ID='KEYID'
export APP_STORE_CONNECT_ISSUER_ID='ISSUER-UUID'
```

### Apple ID environment credentials

```bash
export APPLE_ID='developer@example.com'
export APPLE_TEAM_ID='TEAMID'
export APPLE_APP_SPECIFIC_PASSWORD='app-specific-password'
```

Build the public package:

```bash
./script/package_dmg.sh
```

The script builds a universal Release app, signs it with hardened runtime and a secure timestamp, notarizes and staples the app, creates and signs the DMG, then notarizes, staples, and verifies the DMG. It also writes `Release/MacResourceBar-1.2.dmg.sha256`. It exits before building if a public package lacks signing or notarization credentials.

## Source and runtime checks

Before public packaging:

```bash
swift test
./script/build_and_run.sh --verify
```

Inspect the live menu bar, popover, search, sorting, filters, settings, persisted order, and refresh modes. Measure idle and open-popover overhead with `script/measure_overhead.swift`; it includes short-lived helper CPU. GitHub Actions validates the tests and a universal Release build. CI success does not replace signing, notarization, or native UI acceptance.

Local mode does not notarize or use a signing identity from the shell. Packaging works in a unique temporary directory and leaves the previous output untouched when building or validation fails. DMG layout is written directly without Finder automation.

## Pre-publish checks

```bash
codesign --verify --deep --strict --verbose=2 Release/MacResourceBar.app
xcrun stapler validate Release/MacResourceBar.app
xcrun stapler validate Release/MacResourceBar-1.2.dmg
spctl --assess --type execute --verbose=2 Release/MacResourceBar.app
hdiutil verify Release/MacResourceBar-1.2.dmg
lipo -archs Release/MacResourceBar.app/Contents/MacOS/MacResourceBar
```

Expected architectures are `x86_64 arm64` in either order. Publish only the notarized public artifact and its checksum.
