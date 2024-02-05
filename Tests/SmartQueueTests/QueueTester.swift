
import Foundation

class QueueTester {
    enum QueueTestError: Error {
        case unauthorized
        case invalidPassword
    }

    private struct RequestTask {
        let id: UUID
        let bearer: UUID
        let continuation: CheckedContinuation<String, Error>
    }

    private struct RefreshTask {
        let id: UUID
        let refreshToken: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var requestQueue: [RequestTask] = []
    private var refreshQueue: [RefreshTask] = []
    private var knownUUIDS: [UUID] = []
    private var knownCompletedUUIDS: [UUID] = []
    let currentPassword: String
    private var refreshToken: UUID?
    private var accessToken: UUID?

    public var requestCount: Int { requestQueue.count }
    public var refrehCount: Int { refreshQueue.count }

    init(password: String) {
        currentPassword = password
    }

    public struct RequestPackage {
        let requestId: UUID
        let queueTester: QueueTester

        init(queueTester: QueueTester) {
            requestId = .init()
            self.queueTester = queueTester
        }

        public func request(bearer: UUID) async throws -> String {
            try await queueTester.request(requestId: requestId, bearer: bearer)
        }

        public func completeRequest(with f: @escaping (QueueTester, _ bearer: UUID) async throws -> String) async {
            await queueTester.completeRequest(requestId: requestId, with: f)
        }

        public func completeRequest(with string: String) async {
            await queueTester.completeRequest(requestId: requestId, with: {
                _, _ in string
            })
        }
    }

    public func requestPackage() -> RequestPackage {
        .init(queueTester: self)
    }

    public func login(password: String) async throws -> UUID {
        try await Task.sleep(nanoseconds: 100_000)
        await Task.yield()
        guard currentPassword == password else {
            throw QueueTestError.invalidPassword
        }
        let newToken = UUID()
        refreshToken = newToken
        return newToken
    }

    public func invalidateAccessToken() async throws {
        try await Task.sleep(nanoseconds: 100_000)
        await Task.yield()
        accessToken = nil
    }

    public func logout() async throws {
        try await Task.sleep(nanoseconds: 100_000)
        await Task.yield()
        accessToken = nil
        refreshToken = nil
    }

    private func addKnownUUID(uuid: UUID) {
        guard knownUUIDS.contains(uuid) == false else {
            fatalError()
        }
        knownUUIDS.append(uuid)
    }

    private func addKnownCompletedUUID(uuid: UUID) {
        guard knownCompletedUUIDS.contains(uuid) == false else {
            fatalError()
        }
        knownCompletedUUIDS.append(uuid)
    }

    private func request(requestId: UUID, bearer: UUID) async throws -> String {
        addKnownUUID(uuid: requestId)
        return try await withCheckedThrowingContinuation { continuation in
            requestQueue.append(RequestTask(id: requestId, bearer: bearer, continuation: continuation))
        }
    }

    private func completeRequest(requestId: UUID, with f: @escaping (QueueTester, _ bearer: UUID) async throws -> String) async {
        addKnownCompletedUUID(uuid: requestId)
        Task {
            while true {
                await Task.yield()
                try await Task.sleep(nanoseconds: 100_000)
                if let request = self.requestQueue.filter({ $0.id == requestId }).first {
                    self.requestQueue = self.requestQueue.filter {
                        $0.id != requestId
                    }
                    do {
                        let response = try await f(self, request.bearer)
                        guard request.bearer == self.accessToken else {
                            throw QueueTestError.unauthorized
                        }
                        request.continuation.resume(returning: response)
                        return
                    } catch {
                        request.continuation.resume(throwing: error)
                        return
                    }
                }
            }
        }
    }

    public struct RefreshPackage {
        let refreshId: UUID
        let queueTester: QueueTester

        init(queueTester: QueueTester) {
            refreshId = .init()
            self.queueTester = queueTester
        }

        public func refresh(refreshToken: UUID) async throws -> UUID {
            try await queueTester.refresh(refreshId: refreshId, refreshToken: refreshToken)
        }

        public func completeRefresh(with f: @escaping (_ tester: QueueTester, _ refreshToken: UUID) async throws -> UUID) async {
            await queueTester.completeRefresh(refreshId: refreshId, with: f)
        }

        public func completeRefresh() async {
            await queueTester.completeRefresh(refreshId: refreshId, with: { _, _ in
                UUID()
            })
        }
    }

    public func refreshPackage() -> RefreshPackage {
        .init(queueTester: self)
    }

    private func refresh(refreshId: UUID, refreshToken: UUID) async throws -> UUID {
        addKnownUUID(uuid: refreshId)
        return try await withCheckedThrowingContinuation { continuation in
            refreshQueue.append(RefreshTask(id: refreshId, refreshToken: refreshToken, continuation: continuation))
        }
    }

    private func completeRefresh(refreshId: UUID, with f: @escaping (QueueTester, _ refreshToken: UUID) async throws -> UUID) async {
        addKnownCompletedUUID(uuid: refreshId)
        Task {
            while true {
                try await Task.sleep(nanoseconds: 100_000)
                await Task.yield()
                if let refresh = self.refreshQueue.filter({ $0.id == refreshId }).first {
                    self.refreshQueue = self.refreshQueue.filter {
                        $0.id != refreshId
                    }
                    do {
                        let response = try await f(self, refresh.refreshToken)
                        guard refresh.refreshToken == self.refreshToken else {
                            throw QueueTestError.unauthorized
                        }
                        self.accessToken = response
                        refresh.continuation.resume(returning: response)
                        return
                    } catch {
                        refresh.continuation.resume(throwing: error)
                        return
                    }
                }
            }
        }
    }
}
