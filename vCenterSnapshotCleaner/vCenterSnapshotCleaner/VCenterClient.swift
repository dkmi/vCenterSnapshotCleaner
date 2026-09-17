import Foundation
import Network

final class VCenterClient: NSObject, URLSessionDelegate {
    private static let connectionTimeout: TimeInterval = 6

    private let settings: ConnectionSettings
    private let cookieStorage = HTTPCookieStorage()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = cookieStorage
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var serviceContent: ServiceContent?
    private var containerViewID: String?
    private var soapCookieHeader: String?
    private var effectiveAPIVersion: String?
    private var reportedAPIVersion: String?

    var detectedAPIVersion: String {
        reportedAPIVersion ?? effectiveAPIVersion ?? "auto"
    }

    init(settings: ConnectionSettings) {
        self.settings = settings
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard settings.allowUntrustedCertificate, let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func login() async throws {
        try await checkReachability()
        let contentDocument = try await retrieveServiceContentWithAutoVersion()
        if let apiVersion = firstValue(contentDocument, element: "apiVersion") {
            reportedAPIVersion = apiVersion
        }

        let content = try ServiceContent(
            sessionManager: requiredValue(contentDocument, element: "sessionManager"),
            propertyCollector: requiredValue(contentDocument, element: "propertyCollector"),
            rootFolder: requiredValue(contentDocument, element: "rootFolder"),
            viewManager: requiredValue(contentDocument, element: "viewManager")
        )
        serviceContent = content

        _ = try await soap("Login") {
            """
            <Login xmlns="urn:vim25">
              <_this type="SessionManager">\(xmlEscape(content.sessionManager))</_this>
              <userName>\(xmlEscape(settings.username))</userName>
              <password>\(xmlEscape(settings.password))</password>
              <locale>en</locale>
            </Login>
            """
        }
    }

    private func retrieveServiceContentWithAutoVersion() async throws -> XMLDocument {
        let configured = settings.apiRelease.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = ([configured].filter { !$0.isEmpty } + [
            "8.0.3",
            "8.0.2",
            "8.0.1",
            "8.0",
            "7.0.3",
            "7.0.2",
            "7.0.1",
            "7.0",
            "6.7",
            "6.5",
            "6.0",
            "5.5"
        ]).reduce(into: [String]()) { result, item in
            if !result.contains(item) {
                result.append(item)
            }
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                effectiveAPIVersion = candidate
                return try await soap("RetrieveServiceContent") {
                    """
                    <RetrieveServiceContent xmlns="urn:vim25">
                      <_this type="ServiceInstance">ServiceInstance</_this>
                    </RetrieveServiceContent>
                    """
                }
            } catch {
                lastError = error
            }
        }

        effectiveAPIVersion = nil
        if let lastError {
            throw lastError
        }
        throw AppError.server("Could not detect vCenter SOAP API version.")
    }

    func logout() async {
        guard let content = serviceContent else { return }
        _ = try? await soap("Logout") {
            """
            <Logout xmlns="urn:vim25">
              <_this type="SessionManager">\(xmlEscape(content.sessionManager))</_this>
            </Logout>
            """
        }
    }

    func findVMsWithSnapshots(progress: @escaping (Int, Int) async -> Void) async throws -> [SnapshotVM] {
        let content = try requireServiceContent()
        let viewID = try await containerViewID(content: content)
        let document = try await soap("RetrievePropertiesEx") {
            """
            <RetrievePropertiesEx xmlns="urn:vim25">
              <_this type="PropertyCollector">\(xmlEscape(content.propertyCollector))</_this>
              <specSet>
                <propSet>
                  <type>VirtualMachine</type>
                  <pathSet>name</pathSet>
                  <pathSet>runtime.powerState</pathSet>
                  <pathSet>runtime.consolidationNeeded</pathSet>
                  <pathSet>snapshot</pathSet>
                  <pathSet>layoutEx</pathSet>
                  <pathSet>recentTask</pathSet>
                </propSet>
                <objectSet>
                  <obj type="ContainerView">\(xmlEscape(viewID))</obj>
                  <skip>true</skip>
                  <selectSet xsi:type="TraversalSpec" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                    <name>view</name>
                    <type>ContainerView</type>
                    <path>view</path>
                    <skip>false</skip>
                  </selectSet>
                </objectSet>
              </specSet>
              <options/>
            </RetrievePropertiesEx>
            """
        }

        let parsed = parseVMs(from: document)
        var matches: [SnapshotVM] = []
        for (index, item) in parsed.enumerated() {
            await progress(index + 1, parsed.count)
            guard !item.snapshots.isEmpty || item.consolidationNeeded else { continue }
            let taskInfos = try await taskInfo(for: item.recentTasks)
            let blocking = taskInfos.filter { ["pending", "queued", "running"].contains($0.state.lowercased()) }
            let vm = VMSummary(vm: item.id, name: item.name, powerState: item.powerState)
            matches.append(SnapshotVM(vm: vm, snapshots: item.snapshots, blockingTasks: blocking, consolidationNeeded: item.consolidationNeeded))
        }

        return matches.sorted { $0.vm.name.localizedCaseInsensitiveCompare($1.vm.name) == .orderedAscending }
    }

    func deleteAllSnapshots(for vm: SnapshotVM) async throws -> String {
        let recentTasks = try await recentTasks(for: vm.vm.vm)
        let blocking = try await taskInfo(for: recentTasks).filter { ["pending", "queued", "running"].contains($0.state.lowercased()) }
        guard blocking.isEmpty else {
            throw AppError.server("The VM has active tasks. Snapshots were not deleted.")
        }

        let document = try await soap("RemoveAllSnapshots_Task") {
            """
            <RemoveAllSnapshots_Task xmlns="urn:vim25">
              <_this type="VirtualMachine">\(xmlEscape(vm.vm.vm))</_this>
              <consolidate>true</consolidate>
            </RemoveAllSnapshots_Task>
            """
        }
        return firstValue(document, element: "returnval") ?? "task"
    }

    func deleteSnapshot(_ snapshot: SnapshotInfo, for vm: SnapshotVM) async throws -> String {
        let recentTasks = try await recentTasks(for: vm.vm.vm)
        let blocking = try await taskInfo(for: recentTasks).filter { ["pending", "queued", "running"].contains($0.state.lowercased()) }
        guard blocking.isEmpty else {
            throw AppError.server("The VM has active tasks. Snapshot was not deleted.")
        }

        let document = try await soap("RemoveSnapshot_Task") {
            """
            <RemoveSnapshot_Task xmlns="urn:vim25">
              <_this type="VirtualMachineSnapshot">\(xmlEscape(snapshot.id))</_this>
              <removeChildren>false</removeChildren>
              <consolidate>true</consolidate>
            </RemoveSnapshot_Task>
            """
        }
        return firstValue(document, element: "returnval") ?? "task"
    }

    func consolidateDisks(for vm: SnapshotVM) async throws -> String {
        let recentTasks = try await recentTasks(for: vm.vm.vm)
        let blocking = try await taskInfo(for: recentTasks).filter { ["pending", "queued", "running"].contains($0.state.lowercased()) }
        guard blocking.isEmpty else {
            throw AppError.server("The VM has active tasks. Consolidation was not started.")
        }

        let document = try await soap("ConsolidateVMDisks_Task") {
            """
            <ConsolidateVMDisks_Task xmlns="urn:vim25">
              <_this type="VirtualMachine">\(xmlEscape(vm.vm.vm))</_this>
            </ConsolidateVMDisks_Task>
            """
        }
        return firstValue(document, element: "returnval") ?? "task"
    }

    func waitForTask(_ taskID: String, progress: @escaping (TaskInfo) async -> Void) async throws -> TaskInfo {
        while true {
            let task = try await taskInfo(for: [taskID]).first ?? TaskInfo(id: taskID, name: taskID, state: "unknown", progress: nil)
            await progress(task)

            switch task.state.lowercased() {
            case "success":
                return task
            case "error":
                throw AppError.server("vCenter task \(taskID) failed.")
            default:
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func recentTasks(for vmID: String) async throws -> [String] {
        let content = try requireServiceContent()
        let document = try await soap("RetrievePropertiesEx") {
            """
            <RetrievePropertiesEx xmlns="urn:vim25">
              <_this type="PropertyCollector">\(xmlEscape(content.propertyCollector))</_this>
              <specSet>
                <propSet>
                  <type>VirtualMachine</type>
                  <pathSet>recentTask</pathSet>
                </propSet>
                <objectSet>
                  <obj type="VirtualMachine">\(xmlEscape(vmID))</obj>
                  <skip>false</skip>
                </objectSet>
              </specSet>
              <options/>
            </RetrievePropertiesEx>
            """
        }
        return parseVMs(from: document).first?.recentTasks ?? []
    }

    private func taskInfo(for refs: [String]) async throws -> [TaskInfo] {
        let content = try requireServiceContent()
        var tasks: [TaskInfo] = []

        for ref in refs {
            let document = try await soap("RetrievePropertiesEx") {
                """
                <RetrievePropertiesEx xmlns="urn:vim25">
                  <_this type="PropertyCollector">\(xmlEscape(content.propertyCollector))</_this>
                  <specSet>
                    <propSet>
                      <type>Task</type>
                      <pathSet>info.state</pathSet>
                      <pathSet>info.name</pathSet>
                      <pathSet>info.descriptionId</pathSet>
                      <pathSet>info.progress</pathSet>
                    </propSet>
                    <objectSet>
                      <obj type="Task">\(xmlEscape(ref))</obj>
                      <skip>false</skip>
                    </objectSet>
                  </specSet>
                  <options/>
                </RetrievePropertiesEx>
                """
            }
            let props = propertyMap(from: document).first?.props ?? [:]
            let state = props["info.state"]?.firstText ?? "unknown"
            let name = props["info.name"]?.firstText ?? props["info.descriptionId"]?.firstText ?? ref
            let progress = props["info.progress"]?.firstText.flatMap(Int.init)
            tasks.append(TaskInfo(id: ref, name: name, state: state, progress: progress))
        }

        return tasks
    }

    private func containerViewID(content: ServiceContent) async throws -> String {
        if let containerViewID { return containerViewID }

        let document = try await soap("CreateContainerView") {
            """
            <CreateContainerView xmlns="urn:vim25">
              <_this type="ViewManager">\(xmlEscape(content.viewManager))</_this>
              <container type="Folder">\(xmlEscape(content.rootFolder))</container>
              <type>VirtualMachine</type>
              <recursive>true</recursive>
            </CreateContainerView>
            """
        }
        guard let id = firstValue(document, element: "returnval") else {
            throw AppError.invalidResponse
        }
        containerViewID = id
        return id
    }

    private func soap(_ action: String, body: () -> String) async throws -> XMLDocument {
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?>
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
          <soapenv:Body>
            \(body())
          </soapenv:Body>
        </soapenv:Envelope>
        """

        var request = try soapRequest(action: action)
        request.httpBody = envelope.data(using: .utf8)
        let data = try await perform(request)
        let document = try XMLDocument(data: data, options: [.nodePreserveAll])
        if let fault = firstValue(document, element: "faultstring") {
            throw AppError.server("\(action): \(fault)")
        }
        return document
    }

    private func soapRequest(action: String) throws -> URLRequest {
        guard let url = URL(string: normalizedBaseURL() + "/sdk") else {
            throw AppError.invalidHost
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/xml", forHTTPHeaderField: "Accept")
        request.setValue("\"urn:vim25/\(effectiveAPIVersion ?? "6.5")\"", forHTTPHeaderField: "SOAPAction")
        if let soapCookieHeader {
            request.setValue(soapCookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func checkReachability() async throws {
        guard let url = URL(string: normalizedBaseURL()),
              let host = url.host else {
            throw AppError.invalidHost
        }

        let portNumber = UInt16(url.port ?? 443)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            throw AppError.invalidHost
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let queue = DispatchQueue(label: "vcenter.reachability.\(UUID().uuidString)")
            let gate = CompletionGate()

            @Sendable func finish(_ result: Result<Void, Error>) {
                guard gate.markCompleted() else { return }

                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(AppError.server("Cannot reach \(host):\(portNumber). Check VPN, DNS, firewall, and port 443. Network error: \(error.localizedDescription)")))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + Self.connectionTimeout) {
                finish(.failure(AppError.server("Connection timed out while checking \(host):\(portNumber). Check whether the VPN is connected and vCenter is reachable.")))
            }

            connection.start(queue: queue)
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw AppError.server(networkMessage(for: error))
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        captureSOAPCookie(from: http)
        guard (200..<300).contains(http.statusCode) else {
            let endpoint = request.url?.path ?? "unknown endpoint"
            throw AppError.http(http.statusCode, endpoint, soapFaultMessage(from: data))
        }
        return data
    }

    private func captureSOAPCookie(from response: HTTPURLResponse) {
        let headers = response.allHeaderFields
        let cookieValue = headers["Set-Cookie"] as? String
            ?? headers["set-cookie"] as? String
            ?? headers["SET-COOKIE"] as? String

        guard let cookieValue else { return }
        let cookies = cookieValue
            .split(separator: ",")
            .compactMap { segment -> String? in
                let firstPart = segment.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let firstPart, firstPart.contains("=") else { return nil }
                return firstPart
            }

        if !cookies.isEmpty {
            soapCookieHeader = cookies.joined(separator: "; ")
        }
    }

    private func requireServiceContent() throws -> ServiceContent {
        guard let serviceContent else {
            throw AppError.server("No active vCenter SOAP session.")
        }
        return serviceContent
    }

    private func parseVMs(from document: XMLDocument) -> [ParsedVM] {
        propertyMap(from: document).compactMap { object in
            guard object.type == "VirtualMachine" else { return nil }
            let name = object.props["name"]?.firstText ?? object.id
            let powerState = object.props["runtime.powerState"]?.firstText
            let consolidationNeeded = object.props["runtime.consolidationNeeded"]?.firstText == "true"
            let snapshotSizes = object.props["layoutEx"].map(snapshotSizes(from:)) ?? [:]
            let snapshots = object.props["snapshot"].map { snapshotInfo(from: $0, sizes: snapshotSizes) } ?? []
            let recentTasks = object.props["recentTask"]?.references(type: "Task") ?? []
            return ParsedVM(
                id: object.id,
                name: name,
                powerState: powerState,
                consolidationNeeded: consolidationNeeded,
                snapshots: snapshots,
                recentTasks: recentTasks
            )
        }
    }

    private func propertyMap(from document: XMLDocument) -> [ParsedObject] {
        let objectNodes = (try? document.nodes(forXPath: "//*[local-name()='objects']")) ?? []
        return objectNodes.compactMap { node in
            let element = node as? XMLElement
            guard let obj = element?.firstChildElement(named: "obj"),
                  let id = obj.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

            var props: [String: XMLElement] = [:]
            for prop in element?.childElements(named: "propSet") ?? [] {
                guard let name = prop.firstChildElement(named: "name")?.trimmedText,
                      let val = prop.firstChildElement(named: "val") else { continue }
                props[name] = val
            }

            return ParsedObject(id: id, type: obj.attribute(forName: "type")?.stringValue, props: props)
        }
    }

    private func snapshotInfo(from value: XMLElement, sizes: [String: Int64]) -> [SnapshotInfo] {
        value.childElements(named: "rootSnapshotList").flatMap { snapshotTree(from: $0, sizes: sizes) }
    }

    private func snapshotTree(from element: XMLElement, sizes: [String: Int64]) -> [SnapshotInfo] {
        let snapshotID = element.firstChildElement(named: "snapshot")?.trimmedText ?? UUID().uuidString
        let current = SnapshotInfo(
            id: snapshotID,
            name: element.firstChildElement(named: "name")?.trimmedText ?? snapshotID,
            created: element.firstChildElement(named: "createTime")?.trimmedText,
            state: element.firstChildElement(named: "state")?.trimmedText,
            sizeBytes: sizes[snapshotID]
        )
        let children = element.childElements(named: "childSnapshotList").flatMap { snapshotTree(from: $0, sizes: sizes) }
        return [current] + children
    }

    private func snapshotSizes(from layoutEx: XMLElement) -> [String: Int64] {
        let files = layoutEx.childElements(named: "file").reduce(into: [String: Int64]()) { result, file in
            guard let key = file.firstChildElement(named: "key")?.trimmedText else { return }
            let size = file.firstChildElement(named: "size")?.trimmedText.flatMap(Int64.init) ?? 0
            result[key] = max(result[key] ?? 0, size)
        }

        var sizes: [String: Int64] = [:]
        for snapshotLayout in layoutEx.childElements(named: "snapshot") {
            guard let snapshotID = snapshotLayout.firstChildElement(named: "key")?.trimmedText else { continue }
            var fileKeys = Set<String>()
            for disk in snapshotLayout.childElements(named: "disk") {
                for chain in disk.childElements(named: "chain") {
                    for fileKey in chain.childElements(named: "fileKey") {
                        if let value = fileKey.trimmedText {
                            fileKeys.insert(value)
                        }
                    }
                }
            }
            let total = fileKeys.reduce(Int64(0)) { $0 + (files[$1] ?? 0) }
            sizes[snapshotID] = total
        }
        return sizes
    }

    private func requiredValue(_ document: XMLDocument, element: String) throws -> String {
        guard let value = firstValue(document, element: element) else {
            throw AppError.invalidResponse
        }
        return value
    }

    private func firstValue(_ document: XMLDocument, element: String) -> String? {
        let nodes = try? document.nodes(forXPath: "//*[local-name()='\(element)']")
        return nodes?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func soapFaultMessage(from data: Data) -> String {
        guard let document = try? XMLDocument(data: data) else {
            return String(data: data, encoding: .utf8) ?? "No details returned by vCenter."
        }
        if let fault = firstValue(document, element: "faultstring") {
            if fault.localizedCaseInsensitiveContains("session is not authenticated") {
                return "\(fault). SOAP login succeeded, but vCenter did not receive the session cookie on the next request."
            }
            return fault
        }
        return String(data: data, encoding: .utf8) ?? "No details returned by vCenter."
    }

    private func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "The vCenter TLS certificate is not trusted. Enable \"Allow self-signed TLS\" or add the vCenter certificate to macOS Keychain."
        case .secureConnectionFailed:
            return "The TLS connection to vCenter failed. Check TLS 1.2, cipher support, and the certificate."
        case .cannotFindHost:
            return "The vCenter address cannot be resolved. Check DNS/FQDN or use an IP address."
        case .timedOut:
            return "The request to vCenter timed out. Check whether the VPN is connected and vCenter is reachable."
        case .cannotConnectToHost, .networkConnectionLost:
            return "Cannot connect to vCenter. Check VPN, firewall, and port 443."
        default:
            return error.localizedDescription
        }
    }

    private func normalizedBaseURL() -> String {
        let trimmed = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

private struct ServiceContent {
    let sessionManager: String
    let propertyCollector: String
    let rootFolder: String
    let viewManager: String
}

private struct ParsedObject {
    let id: String
    let type: String?
    let props: [String: XMLElement]
}

private struct ParsedVM {
    let id: String
    let name: String
    let powerState: String?
    let consolidationNeeded: Bool
    let snapshots: [SnapshotInfo]
    let recentTasks: [String]
}

private extension XMLElement {
    var trimmedText: String? {
        stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var firstText: String? {
        trimmedText
    }

    func firstChildElement(named name: String) -> XMLElement? {
        childElements(named: name).first
    }

    func childElements(named name: String) -> [XMLElement] {
        children?.compactMap { child in
            guard let element = child as? XMLElement, element.matchesName(name) else { return nil }
            return element
        } ?? []
    }

    func references(type: String) -> [String] {
        childElements(named: "ManagedObjectReference")
            .filter { $0.typeAttribute == type }
            .compactMap(\.trimmedText)
    }

    private func matchesName(_ expected: String) -> Bool {
        localName == expected || name == expected
    }

    private var typeAttribute: String? {
        attribute(forName: "type")?.stringValue
            ?? attribute(forName: "xsi:type")?.stringValue
    }
}
