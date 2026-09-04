# MacResourceBar

Native macOS menu-bar resource monitor. Product name: MacResourceBar; source/project directory: `NetworkMenuMonitor`. Read `README.md` and `Package.swift` for the current structure.

- Keep unavailable/warming-up metrics distinct from zero. Preserve units, sampling intervals, process identity, and the distinction between system totals and per-process estimates.
- Avoid double-counting VPN/interface traffic and helper processes. Validate counter resets, process exit/PID reuse, missing permissions, and stale samples when those paths change.
- Use `swift test` for the Swift package tests and the Xcode/build scripts for application changes. `./script/build_and_run.sh --verify` builds and launches the app; inspect its effects before using it on an active installation.
- Verify the actual menu-bar app, popover, settings, and sampling behavior after UI/runtime changes. An accessibility click or running PID without the intended visible state is insufficient.
- Measure monitoring overhead under a representative workload for sampling/performance changes. Do not terminate user processes as an incidental test.
- Follow `RELEASE.md` for authorized releases. Local ad-hoc packages are development artifacts; public packaging requires the repository's signing/notarization checks.
