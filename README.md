# vCenter Snapshot Cleaner

A macOS SwiftUI application for managing VMware vCenter snapshots over the SOAP API, including vCenter 6.5.

## Projects

- `vCenterSnapshotCleaner`: macOS 12 or later, Intel and Apple Silicon.
- `vCenterSnapshotCleaner-macOS14-AppleSilicon`: macOS 14 or later, Apple Silicon, with the modern SwiftUI interface.

Open the `.xcodeproj` inside the desired folder in Xcode. Each project has its own README with build and usage details.

## Features

- Automatic API version detection and connection timeout handling.
- VM snapshot discovery, snapshot sizes, and individual or all-snapshot deletion.
- Operation checks and visible task progress.
- Consolidation detection and execution.
- Server address book without stored passwords.
- Resuming monitoring of snapshot deletion tasks after reconnecting.
- Disconnect control.
