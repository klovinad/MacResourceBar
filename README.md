# NetworkMenuMonitor

## 1. Feasibility assessment

### What is feasible with standard public APIs

- Accurate total download and upload throughput for the whole machine is feasible with public BSD/macOS networking APIs by reading interface byte counters via `getifaddrs`.
- Per-process CPU, RAM and disk counters are available through process APIs such as `proc_pidinfo` and `proc_pid_rusage`.
- A native menu bar app with SwiftUI, launch-at-login, and low/high refresh behavior is feasible with standard AppKit/SwiftUI/ServiceManagement APIs.

### What is not cleanly feasible with standard public APIs

- Live per-application network attribution is not exposed as a stable public API surface.
- A fully accurate per-app monitor usually moves toward Network Extension, packet inspection, or other privileged/entitled architectures, especially if you need robust attribution across all traffic types and sandbox boundaries.

### Best realistic MVP

- This MVP uses public APIs for total traffic.
- Per-process network values are collected from `nettop` as best-effort data.
- CPU and RAM are collected from `proc_pidinfo` and disk I/O from `proc_pid_rusage`.
- All per-app metrics are merged in a single stream to render a unified resource table.

## 2. Recommended architecture

- `NetworkTotalsMonitor`: reads interface counters and computes total download/upload bytes per second.
- `NetworkProcessMonitor` (`NetTopProcessMonitor.swift`): launches `/usr/sbin/nettop`, parses CSV delta output, and emits per-process network rows.
- `CPUProcessMonitor`: samples per-process CPU usage (`proc_pidinfo`).
- `MemoryProcessMonitor`: samples per-process resident memory.
- `DiskProcessMonitor`: samples per-process read/write activity (`proc_pid_rusage`).
- `AppResourceMonitor`: aggregates CPU/RAM/disk/network per app and emits unified `AppResourceSnapshot` rows.
- `MenuBarViewModel`: applies filtering, sorting, thresholding, and formats menu bar text.
- SwiftUI views: show the menu bar extra and the resource table in the popover.
- `LaunchAtLoginService`: wraps `SMAppService.mainApp`.

## 3. Full Xcode-ready source code

The full source is in this repository under [`/Applications/Network app/NetworkMenuMonitor`](/Applications/Network%20app/NetworkMenuMonitor) with the project at [`/Applications/Network app/NetworkMenuMonitor.xcodeproj`](/Applications/Network app/NetworkMenuMonitor.xcodeproj).

## 4. Project structure by files and folders

```text
Network app/
├── NetworkMenuMonitor.xcodeproj/
│   └── project.pbxproj
├── NetworkMenuMonitor/
│   ├── Info.plist
│   ├── NetworkMenuMonitorApp.swift
│   ├── Models/
│   │   └── AppTrafficSnapshot.swift
│   ├── Services/
│   │   ├── LaunchAtLoginService.swift
│   │   ├── NetTopProcessMonitor.swift
│   │   ├── CPUProcessMonitor.swift
│   │   ├── MemoryProcessMonitor.swift
│   │   ├── DiskProcessMonitor.swift
│   │   ├── AppResourceMonitor.swift
│   │   └── NetworkTotalsMonitor.swift
│   ├── Utilities/
│   │   └── ByteRateFormatter.swift
│   ├── ViewModels/
│   │   └── MenuBarViewModel.swift
│   └── Views/
│       └── MenuBarPopoverView.swift
└── README.md
```

## 5. Setup steps in Xcode

1. Open [`/Applications/Network app/NetworkMenuMonitor.xcodeproj`](/Applications/Network%20app/NetworkMenuMonitor.xcodeproj).
2. Select the `NetworkMenuMonitor` target.
3. Set your development team if you want to run it signed on your Mac.
4. Build and run the `NetworkMenuMonitor` scheme.

## 6. Launch-at-login implementation details

- The app uses `SMAppService.mainApp`.
- The popover contains a toggle that calls `register()` or `unregister()`.
- This is the modern macOS approach for a normal app target and avoids the older helper-app login item pattern for this MVP.

## 7. Permissions / entitlements / capabilities required

- No special entitlements are required for the basic MVP.
- No packet capture entitlement is used.
- The total-throughput monitor uses standard interface counters.
- Per-app network values depend on `/usr/sbin/nettop`.
- Per-app CPU/RAM/disk counters are obtained from process APIs for currently visible running applications.

## 8. Known limitations

- Per-app network values are best-effort based on `nettop` output and can change with OS versions.
- Some rows represent helper processes instead of the parent branded app.
- Process icons are resolved from `NSRunningApplication` when possible; background daemons may show a generic icon.
- The first `nettop` sample is discarded because delta mode starts with baseline totals, not interval deltas.
- Some rows may have delayed activity due to process lifecycle timing and polling cadence.
- When `nettop` cannot launch or parse, the menu bar total still works and the popover shows an explanatory status.

## 9. Naming

- Product: `NetworkMenuMonitor`
- Bundle ID: `com.networkmenumonitor.app`

## 10. Next steps to evolve the MVP into a more accurate per-app monitor

- Move per-app attribution to a privileged architecture such as a Network Extension or system extension design.
- Correlate sockets more robustly to bundle identifiers and app groups.
- Add historical charts and rolling averages for smoother readings.
- Add user preferences for refresh rate, units, and hide-by-default rules.
