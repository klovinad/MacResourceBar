# Local validation — 2026-09-07

MacResourceBar **1.2 (4)** was built and checked on an Apple silicon Mac running macOS 27.0. The universal binary contains both `arm64` and `x86_64`; Intel execution and macOS 13 execution have not been tested on physical hardware.

## Automated checks

- `swift test`: **25 tests passed**. Coverage includes CPU time-unit conversion against an independent native measurement, live process memory reads, 64-bit network-counter decoding, counter resets, PID reuse, unavailable metrics, bounded `nettop` failure handling, helper grouping, filters, preference reload, and continued CPU/memory sampling during slow disk discovery.
- `./script/build_and_run.sh --build-only`: Debug build passed.
- `RELEASE_DIR=Release/qa/2026-09-07/package ./script/package_dmg.sh`: universal Release app and local DMG passed build, strict code-signature verification, architecture checks, and `hdiutil verify`.
- Shell syntax checks and independent Swift typechecks passed for the build, packaging, launch, and measurement scripts.
- `RELEASE_MODE=public ./script/package_dmg.sh` exited with status 2 because a Developer ID Application identity is missing. No public artifact was produced.

## Installed application

The package was installed at the standard Applications location after preserving the previous bundle and preferences locally. A release receipt verified the installed bundle tree, the executable checksum, the running executable path, and its mapped inode against the built package.

Live checks observed:

- The popover opens and reports system CPU, memory, temperature, disk and network activity under concurrent media transfers.
- Full, Compact and Mini can be selected from the popover header. Both refresh options update their selected state; the same selection appears in Settings.
- Search narrows the table by application name, the no-match state appears for a temporary query, and clearing that query restores the list.
- General and Menu Bar settings render with the saved tray order, external disks, opacity, source and launch preference. Network totals warm up and report the selected interface after a refresh-mode change.
- Closing the popover stops per-application sampling. No persistent child `nettop` remained during the closed-panel check.

Synthetic UI text entry was occasionally interrupted by concurrent user interaction. Successful checks above were accepted from the resulting visible state, not from the action response alone. Process termination, launch-at-login changes and permission changes were not exercised against user applications.

## Responsiveness and overhead

Measurements are local observations under an active workload, not a cross-device benchmark. CPU percentages use one logical core as 100%. The measurement script includes CPU consumed by reaped helper processes.

| Scenario | Observation |
| --- | --- |
| First popover layout | 301 ms |
| Repeated popover layout | 54–106 ms |
| Closed panel, 10-second refresh, 30 seconds | 0.48% application CPU + 0.13% helpers = **0.61% combined**; about 74 MiB physical footprint |
| Closed panel, 1-second refresh, 20 seconds | **2.42%** application CPU; about 69 MiB footprint |
| Visible portions of a 60-second interaction session, 1-second refresh | About **11.3%** application CPU + 0.3% helpers over 25 fully visible one-second samples; included search, style changes and accessibility inspection |

The initial 18.6% measurement mixed open and closed panel time and is not a comparable steady-state baseline. Visibility logs were used for the final measurements. The layout timer covers the synchronous show/layout path; it is not a display-frame or input-latency measurement. Steady open-panel overhead without UI automation and subjective interaction quality should also be checked by a person.

Local receipts, timing logs, measurements and rollback files live under the ignored `Release/qa/2026-09-07/` directory. They contain machine-specific evidence and are not part of the public repository.

## Public release gate

**The source and local development package are checked; the public installer remains on hold.** The local app and DMG use ad-hoc signing. Follow [RELEASE.md](../RELEASE.md) to supply Developer ID Application signing, notarize and staple the app and DMG, and pass Gatekeeper assessment before publishing a binary release.
