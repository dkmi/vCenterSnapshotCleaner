import Foundation

@MainActor
final class SnapshotViewModel: ObservableObject {
    @Published var settings = ConnectionSettings()
    @Published var machines: [SnapshotVM] = []
    @Published var selectedMachineID: SnapshotVM.ID?
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var status = "Ready."
    @Published var progressValue: Double?
    @Published var progressLabel: String?
    @Published var errorMessage: String?
    @Published var addressBook: [AddressBookEntry] = []
    @Published var selectedAddressID: AddressBookEntry.ID?
    @Published var activeDeletion: ActiveDeletion?
    @Published var detectedAPIVersion = "Auto"

    private var client: VCenterClient?
    private let addressBookKey = "vcenterSnapshotCleaner.addressBook"
    private let activeDeletionKey = "vcenterSnapshotCleaner.activeDeletion"

    var selectedMachine: SnapshotVM? {
        machines.first { $0.id == selectedMachineID }
    }

    init() {
        addressBook = Self.load([AddressBookEntry].self, key: addressBookKey) ?? []
        activeDeletion = Self.load(ActiveDeletion.self, key: activeDeletionKey)
        if let first = addressBook.first {
            selectedAddressID = first.id
            first.apply(to: &settings)
        }
    }

    func applySelectedAddress() {
        guard let selectedAddressID,
              let entry = addressBook.first(where: { $0.id == selectedAddressID }) else { return }
        let password = settings.password
        entry.apply(to: &settings)
        settings.password = password
        status = "Loaded \(entry.name). Password was not restored."
    }

    func saveCurrentAddress() {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty else {
            errorMessage = "Enter vCenter address and username before saving."
            return
        }

        let name = host
        let entry = AddressBookEntry(
            name: name,
            host: host,
            username: username,
            apiRelease: settings.apiRelease,
            allowUntrustedCertificate: settings.allowUntrustedCertificate
        )

        if let index = addressBook.firstIndex(where: { $0.host == host && $0.username == username }) {
            addressBook[index] = AddressBookEntry(
                id: addressBook[index].id,
                name: addressBook[index].name,
                host: entry.host,
                username: entry.username,
                apiRelease: entry.apiRelease,
                allowUntrustedCertificate: entry.allowUntrustedCertificate
            )
            selectedAddressID = addressBook[index].id
        } else {
            addressBook.append(entry)
            selectedAddressID = entry.id
        }

        persistAddressBook()
        status = "Address saved without password."
    }

    func deleteSelectedAddress() {
        guard let selectedAddressID else { return }
        addressBook.removeAll { $0.id == selectedAddressID }
        self.selectedAddressID = addressBook.first?.id
        persistAddressBook()
        if let first = addressBook.first {
            let password = settings.password
            first.apply(to: &settings)
            settings.password = password
        }
        status = "Address removed."
    }

    func scan() {
        guard !settings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.username.isEmpty,
              !settings.password.isEmpty else {
            errorMessage = "Enter vCenter address, username, and password."
            return
        }

        isBusy = true
        errorMessage = nil
        machines = []
        selectedMachineID = nil
        progressValue = nil
        progressLabel = nil
        status = "Checking network reachability..."
        detectedAPIVersion = "Detecting..."

        Task {
            let newClient = VCenterClient(settings: settings)
            do {
                try await newClient.login()
                client = newClient
                isConnected = true
                settings.apiRelease = newClient.detectedAPIVersion
                detectedAPIVersion = newClient.detectedAPIVersion
                status = "Reading virtual machines..."
                let found = try await newClient.findVMsWithSnapshots { [weak self] current, total in
                    await MainActor.run {
                        self?.progressValue = total > 0 ? Double(current) / Double(total) : nil
                        self?.progressLabel = "Scanning VM \(current) of \(total)"
                        self?.status = "Scanning VM \(current) of \(total)..."
                    }
                }
                machines = found
                selectedMachineID = found.first?.id
                status = found.isEmpty ? "No snapshots or consolidation issues found." : "Found \(found.count) VM\(found.count == 1 ? "" : "s") with snapshots or consolidation needed."
            } catch {
                client = nil
                isConnected = false
                errorMessage = error.localizedDescription
                status = "Error."
                detectedAPIVersion = "Auto"
            }
            progressValue = nil
            progressLabel = nil
            isBusy = false
        }
    }

    func disconnect() {
        guard let client else {
            status = "Already disconnected."
            return
        }

        isBusy = true
        errorMessage = nil
        progressValue = nil
        progressLabel = "Disconnecting"
        status = "Disconnecting from vCenter..."

        Task {
            await client.logout()
            self.client = nil
            isConnected = false
            machines = []
            selectedMachineID = nil
            progressValue = nil
            progressLabel = nil
            detectedAPIVersion = "Auto"
            status = "Disconnected."
            isBusy = false
        }
    }

    func deleteSnapshots(for machine: SnapshotVM) {
        guard let client else {
            errorMessage = "Run a scan first."
            return
        }

        isBusy = true
        errorMessage = nil
        progressValue = nil
        progressLabel = "Preparing delete task"
        status = "Checking active tasks on \(machine.vm.name)..."
        detectedAPIVersion = client.detectedAPIVersion

        Task {
            do {
                let taskID = try await client.deleteAllSnapshots(for: machine)
                saveActiveDeletion(taskID: taskID, machine: machine, snapshot: nil)
                status = "Delete task started: \(taskID). Waiting for vCenter..."
                progressLabel = "Deleting snapshots"
                progressValue = nil

                try await waitForActiveDeletion(using: client, targetName: machine.vm.name)
            } catch {
                errorMessage = error.localizedDescription
                status = "Delete stopped."
            }
            progressValue = nil
            progressLabel = nil
            isBusy = false
        }
    }

    func deleteSnapshot(_ snapshot: SnapshotInfo, from machine: SnapshotVM) {
        guard let client else {
            errorMessage = "Run a scan first."
            return
        }

        isBusy = true
        errorMessage = nil
        progressValue = nil
        progressLabel = "Preparing delete task"
        status = "Checking active tasks on \(machine.vm.name)..."
        detectedAPIVersion = client.detectedAPIVersion

        Task {
            do {
                let taskID = try await client.deleteSnapshot(snapshot, for: machine)
                saveActiveDeletion(taskID: taskID, machine: machine, snapshot: snapshot)
                status = "Delete task started: \(taskID). Waiting for vCenter..."
                progressLabel = "Deleting \(snapshot.name)"
                progressValue = nil

                try await waitForActiveDeletion(using: client, targetName: "\(machine.vm.name) / \(snapshot.name)")
            } catch {
                errorMessage = error.localizedDescription
                status = "Delete stopped."
            }
            progressValue = nil
            progressLabel = nil
            isBusy = false
        }
    }

    func consolidateDisks(for machine: SnapshotVM) {
        guard let client else {
            errorMessage = "Run a scan first."
            return
        }

        isBusy = true
        errorMessage = nil
        progressValue = nil
        progressLabel = "Preparing consolidation task"
        status = "Checking active tasks on \(machine.vm.name)..."
        detectedAPIVersion = client.detectedAPIVersion

        Task {
            do {
                let taskID = try await client.consolidateDisks(for: machine)
                status = "Consolidation task started: \(taskID). Waiting for vCenter..."
                progressLabel = "Consolidating disks"
                progressValue = nil

                let finalTask = try await client.waitForTask(taskID) { [weak self] task in
                    await MainActor.run {
                        self?.progressValue = task.progress.map { Double($0) / 100.0 }
                        if let percent = task.progress {
                            self?.progressLabel = "Consolidating disks: \(percent)%"
                            self?.status = "Consolidating disks on \(machine.vm.name): \(percent)%..."
                        } else {
                            self?.progressLabel = "Consolidating disks"
                            self?.status = "Consolidating disks on \(machine.vm.name) (\(task.state))..."
                        }
                    }
                }

                progressValue = 1
                progressLabel = "Refreshing inventory"
                status = "Consolidation completed with state \(finalTask.state). Refreshing..."
                try await refreshInventory(preferredSelection: machine.id, using: client)
                status = "Consolidation completed. Inventory refreshed."
            } catch {
                errorMessage = error.localizedDescription
                status = "Consolidation stopped."
            }
            progressValue = nil
            progressLabel = nil
            isBusy = false
        }
    }

    func resumeActiveDeletion() {
        guard let activeDeletion else {
            errorMessage = "No saved delete task to resume."
            return
        }
        guard !settings.password.isEmpty else {
            errorMessage = "Enter the password for \(activeDeletion.username) before resuming. Passwords are not stored."
            return
        }

        settings.host = activeDeletion.host
        settings.username = activeDeletion.username
        settings.apiRelease = activeDeletion.apiRelease
        settings.allowUntrustedCertificate = activeDeletion.allowUntrustedCertificate

        isBusy = true
        errorMessage = nil
        progressValue = nil
        progressLabel = "Resuming delete task"
        status = "Checking network reachability..."

        Task {
            let newClient = VCenterClient(settings: settings)
            do {
                try await newClient.login()
                client = newClient
                isConnected = true
                settings.apiRelease = newClient.detectedAPIVersion
                detectedAPIVersion = newClient.detectedAPIVersion
                try await waitForActiveDeletion(using: newClient, targetName: activeDeletion.targetName)
            } catch {
                client = nil
                isConnected = false
                errorMessage = error.localizedDescription
                status = "Resume stopped."
            }
            progressValue = nil
            progressLabel = nil
            isBusy = false
        }
    }

    func forgetActiveDeletion() {
        activeDeletion = nil
        UserDefaults.standard.removeObject(forKey: activeDeletionKey)
        status = "Saved delete task cleared."
    }

    private func waitForActiveDeletion(using client: VCenterClient, targetName: String) async throws {
        guard let activeDeletion else { return }
        let finalTask = try await client.waitForTask(activeDeletion.taskID) { [weak self] task in
            await MainActor.run {
                let progress = task.progress.map { Double($0) / 100.0 }
                self?.progressValue = progress
                if let percent = task.progress {
                    self?.progressLabel = "Deleting snapshots: \(percent)%"
                    self?.status = "Deleting \(targetName): \(percent)%..."
                } else {
                    self?.progressLabel = "Deleting snapshots"
                    self?.status = "Deleting \(targetName) (\(task.state))..."
                }
            }
        }

        progressValue = 1
        progressLabel = "Refreshing inventory"
        status = "Delete task completed with state \(finalTask.state). Refreshing..."

        try await refreshInventory(preferredSelection: selectedMachineID, using: client)
        forgetActiveDeletion()
        status = machines.isEmpty ? "Delete completed. No snapshots or consolidation issues remain." : "Delete completed. Inventory refreshed."
    }

    private func refreshInventory(preferredSelection: SnapshotVM.ID?, using client: VCenterClient) async throws {
        machines = try await client.findVMsWithSnapshots { [weak self] current, total in
            await MainActor.run {
                self?.progressValue = total > 0 ? Double(current) / Double(total) : nil
                self?.progressLabel = "Refreshing VM \(current) of \(total)"
                self?.status = "Refreshing VM \(current) of \(total)..."
            }
        }
        selectedMachineID = machines.contains { $0.id == preferredSelection } ? preferredSelection : machines.first?.id
    }

    private func saveActiveDeletion(taskID: String, machine: SnapshotVM, snapshot: SnapshotInfo?) {
        let saved = ActiveDeletion(
            taskID: taskID,
            vmID: machine.vm.vm,
            vmName: machine.vm.name,
            snapshotID: snapshot?.id,
            snapshotName: snapshot?.name,
            host: settings.host,
            username: settings.username,
            apiRelease: settings.apiRelease,
            allowUntrustedCertificate: settings.allowUntrustedCertificate,
            startedAt: Date()
        )
        activeDeletion = saved
        Self.save(saved, key: activeDeletionKey)
    }

    private func persistAddressBook() {
        Self.save(addressBook, key: addressBookKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
