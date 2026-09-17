import SwiftUI

struct ContentView: View {
    @StateObject private var model = SnapshotViewModel()
    @State private var confirmDelete: SnapshotVM?
    @State private var confirmSnapshotDelete: SnapshotDeleteRequest?
    @State private var confirmConsolidation: SnapshotVM?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            DetailView(
                model: model,
                confirmDelete: $confirmDelete,
                confirmSnapshotDelete: $confirmSnapshotDelete,
                confirmConsolidation: $confirmConsolidation
            )
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Delete all snapshots?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Delete snapshots", role: .destructive) {
                if let confirmDelete {
                    model.deleteSnapshots(for: confirmDelete)
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("vCenter will start RemoveAllSnapshots_Task only if there are no pending, queued, or running tasks.")
        }
        .confirmationDialog("Delete selected snapshot?", isPresented: Binding(
            get: { confirmSnapshotDelete != nil },
            set: { if !$0 { confirmSnapshotDelete = nil } }
        )) {
            Button("Delete selected snapshot", role: .destructive) {
                if let request = confirmSnapshotDelete {
                    model.deleteSnapshot(request.snapshot, from: request.machine)
                }
                confirmSnapshotDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("vCenter will remove only this snapshot. Child snapshots will be preserved.")
        }
        .confirmationDialog("Consolidate VM disks?", isPresented: Binding(
            get: { confirmConsolidation != nil },
            set: { if !$0 { confirmConsolidation = nil } }
        )) {
            Button("Consolidate disks") {
                if let confirmConsolidation {
                    model.consolidateDisks(for: confirmConsolidation)
                }
                confirmConsolidation = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("vCenter will start ConsolidateVMDisks_Task only if there are no pending, queued, or running tasks.")
        }
    }
}

private struct SnapshotDeleteRequest {
    let machine: SnapshotVM
    let snapshot: SnapshotInfo
}

private struct SidebarView: View {
    @ObservedObject var model: SnapshotViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Address Book") {
                    if model.addressBook.isEmpty {
                        Text("No saved servers.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Server", selection: $model.selectedAddressID) {
                            ForEach(model.addressBook) { entry in
                                Text(entry.label).tag(Optional(entry.id))
                            }
                        }
                        .onChange(of: model.selectedAddressID) { _, _ in
                            model.applySelectedAddress()
                        }
                    }

                    HStack {
                        Button {
                            model.saveCurrentAddress()
                        } label: {
                            Label("Save Current", systemImage: "plus")
                        }
                        .disabled(model.isBusy)

                        Button(role: .destructive) {
                            model.deleteSelectedAddress()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(model.isBusy || model.selectedAddressID == nil)
                    }
                }

                Section("vCenter") {
                    TextField("Address or IP", text: $model.settings.host)
                        .textContentType(.URL)
                    TextField("Username", text: $model.settings.username)
                        .textContentType(.username)
                    SecureField("Password", text: $model.settings.password)
                        .textContentType(.password)
                    HStack {
                        Text("Detected SOAP API")
                        Spacer()
                        Text(model.detectedAPIVersion)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Allow self-signed TLS", isOn: $model.settings.allowUntrustedCertificate)
                }

                if let activeDeletion = model.activeDeletion {
                    Section("Saved Delete Task") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activeDeletion.vmName)
                                .font(.headline)
                            Text("\(activeDeletion.taskID) • \(activeDeletion.host)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button {
                                model.resumeActiveDeletion()
                            } label: {
                                Label("Resume Progress", systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isBusy)

                            Button(role: .destructive) {
                                model.forgetActiveDeletion()
                            } label: {
                                Label("Forget", systemImage: "xmark")
                            }
                            .disabled(model.isBusy)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.top, 8)
            .frame(maxHeight: 390)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.scan()
                    } label: {
                        Label(model.isBusy ? "Working..." : "Scan", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || !model.isConnected)
                }

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.bar)

            List {
                ForEach(model.machines, id: \.id) { item in
                    MachineRow(item: item)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .listRowBackground(model.selectedMachineID == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    .onTapGesture {
                        model.selectedMachineID = item.id
                    }
                }
            }
        }
        .navigationTitle("Snapshots")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.progressLabel ?? "\(model.machines.count) VM\(model.machines.count == 1 ? "" : "s") listed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if model.progressLabel != nil {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }
}

private struct MachineRow: View {
    let item: SnapshotVM

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.vm.name)
                .font(.headline)
                .lineLimit(1)
            Text(snapshotSummary)
                .font(.caption)
                .foregroundColor(item.canDeleteSnapshots ? Color.secondary : Color.orange)
            if item.consolidationNeeded {
                Text("Consolidation needed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var snapshotSummary: String {
        let suffix = item.snapshots.count == 1 ? "" : "s"
        return "\(item.snapshots.count) snapshot\(suffix)"
    }
}

private struct DetailView: View {
    @ObservedObject var model: SnapshotViewModel
    @Binding var confirmDelete: SnapshotVM?
    @Binding var confirmSnapshotDelete: SnapshotDeleteRequest?
    @Binding var confirmConsolidation: SnapshotVM?

    var body: some View {
        Group {
            if let machine = model.selectedMachine {
                VStack(alignment: .leading, spacing: 20) {
                    header(for: machine)
                    OperationProgressView(model: model)
                    blockingTasks(for: machine)
                    snapshots(for: machine)
                    Spacer()
                }
                .padding(24)
            } else {
                ContentUnavailableView(
                    "No VM Selected",
                    systemImage: "externaldrive.badge.magnifyingglass",
                    description: Text("Run a scan to see VMs with snapshots.")
                )
            }
        }
        .navigationTitle(model.selectedMachine?.vm.name ?? "vCenter Snapshot Cleaner")
    }

    private func header(for machine: SnapshotVM) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(machine.vm.name)
                    .font(.largeTitle.bold())
                Text("\(machine.vm.vm) • \(machine.vm.powerState ?? "unknown")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label(
                    machine.consolidationNeeded ? "Disk consolidation needed" : "No disk consolidation needed",
                    systemImage: machine.consolidationNeeded ? "exclamationmark.triangle" : "checkmark.seal"
                )
                .font(.callout)
                .foregroundStyle(machine.consolidationNeeded ? .orange : .green)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Button(role: .destructive) {
                    confirmDelete = machine
                } label: {
                    Label("Delete all snapshots", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!machine.canDeleteSnapshots || model.isBusy)
                .help(machine.canDeleteSnapshots ? "Delete all snapshots" : "There are active tasks or no snapshots")

                Button {
                    confirmConsolidation = machine
                } label: {
                    Label("Consolidate disks", systemImage: "externaldrive.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .disabled(!machine.canConsolidate || model.isBusy)
                .help(machine.canConsolidate ? "Start disk consolidation" : "Consolidation is not needed or the VM has active tasks")
            }
        }
    }

    @ViewBuilder
    private func blockingTasks(for machine: SnapshotVM) -> some View {
        if machine.blockingTasks.isEmpty {
            Label("No pending, queued, or running tasks are blocking deletion.", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Deletion is blocked by active tasks", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                ForEach(machine.blockingTasks) { task in
                    Text("\(task.name) • \(task.state) • \(task.id)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func snapshots(for machine: SnapshotVM) -> some View {
        Table(machine.snapshots) {
            TableColumn("Snapshot") { snapshot in
                Text(snapshot.name)
            }
            TableColumn("ID") { snapshot in
                Text(snapshot.id)
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn("Created") { snapshot in
                Text(snapshot.created ?? "-")
            }
            TableColumn("Size") { snapshot in
                Text(snapshot.formattedSize)
                    .font(.system(.body, design: .monospaced))
            }
            TableColumn("State") { snapshot in
                Text(snapshot.state ?? "-")
            }
            TableColumn("Action") { snapshot in
                Button(role: .destructive) {
                    confirmSnapshotDelete = SnapshotDeleteRequest(machine: machine, snapshot: snapshot)
                } label: {
                    Label("Delete snapshot", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(machine.snapshots.count <= 1 || !machine.canDeleteSnapshots || model.isBusy)
                .help(machine.snapshots.count > 1 ? "Delete only this snapshot" : "Single-snapshot VMs use Delete all snapshots")
            }
        }
    }
}

private struct OperationProgressView: View {
    @ObservedObject var model: SnapshotViewModel

    var body: some View {
        if model.isBusy {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.progressLabel ?? "Working")
                        .font(.headline)
                    Spacer()
                    if let value = model.progressValue {
                        Text("\(Int((value * 100).rounded()))%")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let value = model.progressValue {
                    ProgressView(value: value)
                        .controlSize(.large)
                        .scaleEffect(x: 1, y: 2.1, anchor: .center)
                        .padding(.vertical, 8)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.vertical, 6)
                }

                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
