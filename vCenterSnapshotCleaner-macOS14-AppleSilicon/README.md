# vCenter Snapshot Cleaner

A macOS SwiftUI Xcode project for vCenter using the legacy vSphere Web Services SOAP API.

This is the Apple Silicon/macOS 14 UI variant.

Minimum supported macOS version: macOS 14.

Build architecture: Apple Silicon only (`arm64`).

The app:

- connects to vCenter through `/sdk`;
- checks TCP reachability before attempting SOAP login;
- supports explicit disconnect through SOAP `Logout`;
- finds all virtual machines with snapshots;
- displays snapshot tree information and estimated snapshot size;
- checks `recentTask` before deletion;
- blocks deletion when `pending`, `queued`, or `running` tasks exist;
- checks whether disk consolidation is needed;
- starts `ConsolidateVMDisks_Task` when consolidation is needed and the VM is not busy;
- starts `RemoveAllSnapshots_Task` for the selected VM;
- starts `RemoveSnapshot_Task` for a selected snapshot when a VM has more than one snapshot;
- waits for the vCenter task to finish and refreshes the inventory afterward.
- stores an address book without passwords;
- saves an in-progress delete task so progress monitoring can be resumed after reconnecting.

## Open

Open:

```text
vCenterSnapshotCleaner.xcodeproj
```

Then run the `vCenterSnapshotCleaner` target from Xcode.

## Inputs

- `vCenter`: FQDN or IP address, for example `vcenter-a.example.local`.
- `User`: vCenter/SSO username.
- `Password`: password.
- `Allow self-signed TLS`: enable only for internal vCenters with self-signed certificates.

The app auto-detects the SOAP API version during `RetrieveServiceContent` and shows it as read-only connection information.

Before login, the app checks whether the vCenter host is reachable on port 443. If VPN is disconnected, the check fails after about 6 seconds instead of leaving the UI waiting on SOAP requests.

Use `Disconnect` to close the current vCenter session. This sends SOAP `Logout`, clears the in-memory client and VM list, but keeps the address book and any saved in-progress task.

## Address Book

Use `Save Current` to store a server profile. Saved profiles contain:

- display name;
- vCenter host;
- last detected SOAP API version hint;
- username;
- self-signed TLS preference.

Passwords are never stored. When you load a saved server, the password field stays unchanged, so enter the password before scanning or resuming a task.

## Resuming Delete Progress

When snapshot deletion starts, the app saves the returned vCenter task id together with the VM and server profile. If the app is closed while deletion is still running, reopen it, select the saved server, enter the password, and click `Resume Progress`.

The app will log in again, poll the saved task, and refresh the VM list after the task reaches `success`. The saved task can also be cleared with `Forget`.

## How It Works

1. Tries compatible SOAPAction versions for `RetrieveServiceContent` against `https://{vcenter}/sdk`.
2. Performs a short TCP reachability check to `{vcenter}:443`.
3. Reads `about.apiVersion` from vCenter and uses the detected version for later SOAP calls.
4. Logs in through `SessionManager`.
5. Creates a `ContainerView` for all `VirtualMachine` objects.
6. Uses `RetrievePropertiesEx` to read:
   - `name`;
   - `runtime.powerState`;
   - `runtime.consolidationNeeded`;
   - `snapshot`;
   - `layoutEx`;
   - `recentTask`.
7. Reads `Task.info.state`, `Task.info.name`, and `Task.info.progress`.
8. Rechecks `recentTask` before deletion.
9. Calls SOAP method `ConsolidateVMDisks_Task` when consolidation is needed and requested.
10. Calls SOAP method `RemoveAllSnapshots_Task` for all snapshots, or `RemoveSnapshot_Task` for a selected snapshot if the VM has multiple snapshots and is not busy.
11. Polls the returned vCenter task until `success` or `error`.
12. Refreshes the main VM list after the task completes.

## Required vCenter Privileges

The exact minimum depends on inventory and policy, but in practice the user needs:

- `System.View` or equivalent read access on VMs;
- permission to read task and snapshot properties;
- `VirtualMachine.State.RemoveSnapshot` to delete snapshots.
- `VirtualMachine.State.Consolidate` to consolidate disks.

## TLS Errors

If you see `A TLS error caused the secure connection to fail`:

1. enable `Allow self-signed TLS` and try again;
2. use the same FQDN/IP that the certificate was issued for;
3. verify that TLS 1.2 is enabled on older vCenter versions;
4. for production, import the vCenter root/intermediate certificate into macOS Keychain and trust it.

`Info.plist` includes ATS allowances for internal endpoints, but it cannot fix an old TLS/cipher profile on vCenter itself.

## Curl Check

Plain `curl -k -u user:pass https://vcenter/sdk` is not a useful SOAP API test because `/sdk` expects XML `POST` requests. For a quick check:

```bash
export VCENTER=vcenter-a.example.local
export VCENTER_USER='administrator@vsphere.local'
export VCENTER_PASSWORD='your-password'
# optional; defaults to 6.5 for the diagnostic script
export VCENTER_API_VERSION=6.5
./tools/check-vcenter-soap.sh
```

The script runs `RetrieveServiceContent`, finds `sessionManager`, sends SOAP `Login`, creates a `ContainerView` for VMs, and tests `RetrievePropertiesEx`. Useful responses are saved to:

```text
/tmp/vcenter-service-content.xml
/tmp/vcenter-login.xml
/tmp/vcenter-view.xml
/tmp/vcenter-vms.xml
```

## SOAP Fault / HTTP 500

With SOAP, HTTP 500 is often a normal vSphere fault, for example:

- `TaskInProgress`: the VM is busy;
- `InvalidState` or `InvalidPowerState`;
- `SnapshotFault`;
- `NoPermission`.

The app displays `faultstring` when vCenter returns one.

## Important

Snapshot deletion can be a long-running vCenter task and large snapshots can put heavy load on the datastore. The app starts the task, monitors progress, and refreshes the inventory after completion.

Snapshot size is estimated from `VirtualMachine.layoutEx` by summing files associated with each snapshot layout entry. If vCenter does not return layout file size data for a snapshot, the app shows `Unknown`.
