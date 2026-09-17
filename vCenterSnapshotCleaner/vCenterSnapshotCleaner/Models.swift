import Foundation

struct ConnectionSettings: Codable {
    var host: String = ""
    var username: String = ""
    var password: String = ""
    var apiRelease: String = ""
    var allowUntrustedCertificate: Bool = false
}

struct AddressBookEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var username: String
    var apiRelease: String
    var allowUntrustedCertificate: Bool

    var label: String {
        "\(name) (\(username) @ \(host))"
    }

    func apply(to settings: inout ConnectionSettings) {
        settings.host = host
        settings.username = username
        settings.apiRelease = apiRelease
        settings.allowUntrustedCertificate = allowUntrustedCertificate
    }
}

struct ActiveDeletion: Codable, Identifiable, Hashable {
    var id = UUID()
    let taskID: String
    let vmID: String
    let vmName: String
    let snapshotID: String?
    let snapshotName: String?
    let host: String
    let username: String
    let apiRelease: String
    let allowUntrustedCertificate: Bool
    let startedAt: Date

    var targetName: String {
        snapshotName.map { "\(vmName) / \($0)" } ?? vmName
    }
}

struct VMSummary: Codable, Identifiable, Hashable {
    let vm: String
    let name: String
    let powerState: String?

    var id: String { vm }

    enum CodingKeys: String, CodingKey {
        case vm
        case name
        case powerState = "power_state"
    }
}

struct SnapshotInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let created: String?
    let state: String?
    let sizeBytes: Int64?

    var formattedSize: String {
        guard let sizeBytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct TaskInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let progress: Int?
}

struct SnapshotVM: Identifiable, Hashable {
    let vm: VMSummary
    let snapshots: [SnapshotInfo]
    let blockingTasks: [TaskInfo]
    let consolidationNeeded: Bool

    var id: String { vm.id }
    var canDeleteSnapshots: Bool { blockingTasks.isEmpty && !snapshots.isEmpty }
    var canConsolidate: Bool { blockingTasks.isEmpty && consolidationNeeded }
}

struct APIEnvelope<T: Decodable>: Decodable {
    let value: T
}

enum AppError: LocalizedError {
    case invalidHost
    case invalidResponse
    case http(Int, String, String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Invalid vCenter address."
        case .invalidResponse:
            return "vCenter returned an unexpected response."
        case .http(let status, let endpoint, let details):
            return "HTTP \(status) at \(endpoint): \(details)"
        case .server(let message):
            return message
        }
    }
}
