@testable import SmartQueue
import XCTest

final class smart_queueTests: XCTestCase {
    
    func testBasics() async throws {
        
        enum OAuthError {
            case unauthorized
        }

        let password = "bingo"
        let responseValue = "Great stuff \(UUID().uuidString)"
        let tester = QueueTester(password: password)

        let refreshPackage = tester.refreshPackage()
        let requestPackage = tester.requestPackage()

        let refreshToken = try await tester.login(password: password)

        let queue = SmartQueue { _ in
            do {
                return try await .success(refreshPackage.refresh(refreshToken: refreshToken))
            } catch {
                XCTFail()
                fatalError()
            }
        }

        let expectationA = expectation(description: "Got a result")
        let testRun = Task {
            let finalResult = await queue.run { accessToken in
                do {
                    return try await .success(requestPackage.request(bearer: accessToken))
                } catch QueueTester.QueueTestError.unauthorized {
                    return .refreshDependency
                } catch {
                    XCTFail()
                    fatalError()
                }
            }
            if case let .success(value) = finalResult, value == responseValue {
                expectationA.fulfill()
                return value
            } else {
                fatalError()
            }
        }

        await refreshPackage.completeRefresh { _, _ in
            UUID()
        }

        await requestPackage.completeRequest { _, _ in
            responseValue
        }

        let finalValue = await testRun.value
        XCTAssertEqual(finalValue, responseValue)
        await fulfillment(of: [expectationA], timeout: 0.3)
    }

    
    func testWithKnownResponses() async throws {
        
        struct KnownResponse {
            enum RType {
                case final(FinalResult<String>)
                case task(TaskResult<String>)
                case refresh(RefreshTaskResult<UUID>)
            }
            
            let response:RType
            let expectation:XCTestExpectation
            let description:String
            
            init(response: RType, description:String) {
                self.response = response
                let expectation = XCTestExpectation(description: description)
                expectation.expectedFulfillmentCount = 1
                expectation.assertForOverFulfill = true
                self.expectation = expectation
                self.description = description
            }
            
            func getResponse() -> RType {
                expectation.fulfill()
                return response
            }
            
        }
        
        actor Responder {
            let responses:[KnownResponse]
            var index:Int = 0
            
            init(responses: [KnownResponse]) {
                self.responses = responses
            }
            
            func next() async -> KnownResponse {
                try! await Task.sleep(nanoseconds: 1_000_000)
                await Task.yield()
                defer {
                    index += 1
                }
                return self.responses[index]
            }
        }
        
        let uuidA = UUID()
        let uuidB = UUID()
        
        let responder = Responder(responses: [
            KnownResponse(response: .refresh(.success(uuidA)), description: "1 refresh"),
            KnownResponse(response: .task(.success("Hello 1")), description: "1 response"),
            KnownResponse(response: .task(.success("Hello 2")), description: "2 response"),
            KnownResponse(response: .task(.refreshDependency), description: "1 update"),
            KnownResponse(response: .refresh(.success(uuidB)), description: "2 refresh"),
            KnownResponse(response: .task(.success("Hello 3")), description: "3 response"),
            KnownResponse(response: .task(.success("Hello 4")), description: "4 response"),
        ])
        
        let smartQueue = SmartQueue<UUID> { context in
            let response = await responder.next()
            switch response.getResponse() {
                case .refresh(let response):
                    return response
                default:
                    XCTFail("Out of order \(response.description)")
                    fatalError()
            }
        }
        
        let r1 = await smartQueue.run { dependency in
            let response = await responder.next()
            switch response.getResponse() {
                case .task(let response):
                    return response
                default:
                    XCTFail("Out of order \(response.description)")
                    fatalError()
            }
        }
        
        XCTAssertEqual(r1, .success(success: "Hello 1"))
        
        let r2 = await smartQueue.run { dependency in
            let response = await responder.next()
            switch response.getResponse() {
                case .task(let response):
                    return response
                default:
                    XCTFail("Out of order \(response.description)")
                    fatalError()
            }
        }
        
        XCTAssertEqual(r2, .success(success: "Hello 2"))
        
        let r3 = await smartQueue.run { dependency in
            let response = await responder.next()
            switch response.getResponse() {
                case .task(let response):
                    return response
                default:
                    XCTFail("Out of order \(response.description)")
                    fatalError()
            }
        }
        
        XCTAssertEqual(r3, .success(success: "Hello 3"))
        
        
        let r4 = await smartQueue.run { dependency in
            let response = await responder.next()
            switch response.getResponse() {
                case .task(let response):
                    return response
                default:
                    XCTFail("Out of order \(response.description)")
                    fatalError()
            }
        }
        
        XCTAssertEqual(r4, .success(success: "Hello 4"))
        
        
        await fulfillment(of: responder.responses.map(\.expectation), timeout: 2, enforceOrder: true)
        
    }
    
    func testBruteForce() async throws {

        
        let timeLogger = TimeLog()
        
        func timeLog(_ string:String, logger:TimeLog) {
            Task {
                await logger.add(string)
            }
        }
        
        class WonkyResponder {
            var access:Int
            var refreshThreads:Int
            let logger:TimeLog
            
            init(logger:TimeLog) {
                self.access = 0
                self.refreshThreads = 0
                self.logger = logger
            }
            
            func refresh() async -> Int {
                try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<10_000))
                guard self.refreshThreads == 0 else {
                    XCTFail("No more than one refresh thread is allowed at one time")
                    fatalError()
                }
                self.refreshThreads += 1
                defer {
                    self.refreshThreads -= 1
                }
                timeLog("Refreshing to \(self.access)", logger: logger)
                return self.access
            }
            
            func access(token:Int) async -> String? {
                try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<10_000))
                timeLog("Accessing with \(token)", logger: logger)

                guard token == self.access else {
                    timeLog("Bad access with \(token)", logger: logger)
                    return nil
                }
                timeLog("Good access with \(token)", logger: logger)
                return "ac:\(token)"
            }
            
            func reset() async {
                try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<10_000))
                timeLog("Resets \(self.access) to \(self.access+1)", logger: logger)
                self.access += 1
            }
            
        }
        
        let wonky = WonkyResponder(logger: timeLogger)
        
        let queue = SmartQueue<Int> { context in
            return await .success(wonky.refresh())
        }
        
        for _ in 0..<10000 {
            try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<1_000))
            Task {
                if Int.random(in: 0..<10) < 2 {
                    await wonky.reset()
                } else {
                    let _ = await queue.run { token -> TaskResult<String> in
                        let retVal:String? = await wonky.access(token: token)
                        guard let retVal else {
                            return .refreshDependency
                        }
                        return .success(retVal)
                    }
                }
            }
        }
        try! await Task.sleep(nanoseconds: 1_000_000_00)
        await print(timeLogger.textLog())
        
    }
    
    func testControlledResponses() async throws {
        
        
        let timeLogger = TimeLog()
        @Sendable func timeLog(_ string:String) {
            Task {
                await timeLogger.add(string)
            }
        }
        
        @Sendable func execute<T>(_ controlledResponse:ControlledResponse<TaskResult<T>>) async {
            let r:FinalResult<T> = await smartQueue.run { token in
                return await controlledResponse.getResponse()
            }
            timeLog("SmartQueue responded: \(r)")
            
        }
        
        func makeRefresh(_ result:RefreshTaskResult<UUID>, count:Int) -> ControlledResponse<RefreshTaskResult<UUID>> {
            ControlledResponse(response: result, description: "Refresh \(count)", logger: timeLog)
        }
        
        func makeAccessSuccess(count:Int) -> ControlledResponse<TaskResult<String>> {
            ControlledResponse(response: .success("Access \(count)"), description: "Access \(count)", logger: timeLog)
        }
        
        let refreshUuid1 = UUID()
        let refresh1 = makeRefresh(.success(refreshUuid1), count: 1)
        let access1 = makeAccessSuccess(count: 1)
        let access2 = makeAccessSuccess(count: 2)
        
        let smartQueue = SmartQueue<UUID> { context in
            return await refresh1.getResponse()
        }
        
        Task {
            await execute(access1)
            await execute(access2)
        }
        
        Task {
            access1.respond()
            access2.respond()
            refresh1.respond()
        }
        
        try! await Task.sleep(nanoseconds: 1_000_000)
        
        let theLog = await timeLogger.textLog()
        print(theLog)
        
        
    }
    
    func testControlledResponsesWithFailures() async throws {
        
        
        let timeLogger = TimeLog()
        @Sendable func timeLog(_ string:String) {
            Task {
                await timeLogger.add(string)
            }
        }
        
        @Sendable func execute<T>(_ controlledResponse:ControlledResponse<TaskResult<T>>) async {
            let r:FinalResult<T> = await smartQueue.run { token in
                return await controlledResponse.getResponse()
            }
            timeLog("SmartQueue responded: \(r)")
        }

        @Sendable func executeMulti<T>(_ controlledResponse:ControlledMultiResponse<TaskResult<T>>) async {
            let r:FinalResult<T> = await smartQueue.run { token in
                return await controlledResponse.getResponse()
            }
            timeLog("SmartQueue responded: \(r)")
        }

        func makeRefresh(_ result:RefreshTaskResult<UUID>, count:Int) -> ControlledResponse<RefreshTaskResult<UUID>> {
            ControlledResponse(response: result, description: "Refresh \(count)", logger: timeLog)
        }
        
        func makeAccessSuccess(count:Int) -> ControlledResponse<TaskResult<String>> {
            ControlledResponse(response: .success("Access \(count)"), description: "Access \(count)", logger: timeLog)
        }
        
        func makeAccessRefresh(count:Int) -> ControlledMultiResponse<TaskResult<String>> {
            ControlledMultiResponse(description: "Access update \(count)", responses: [.init(value: .refreshDependency), .init(value: .success("AccessX \(count)"))], logger: timeLog)
            
        }
        
        let refreshUuid1 = UUID()
        let refresh1 = makeRefresh(.success(refreshUuid1), count: 1)
        let access1 = makeAccessSuccess(count: 1)
        let access2 = makeAccessSuccess(count: 2)
        let update1 = makeAccessRefresh(count: 3)
        let access3 = makeAccessSuccess(count: 4)

        let smartQueue = SmartQueue<UUID> { context in
            return await refresh1.getResponse()
        }
        
        Task {
            await execute(access1)
            await execute(access2)
            await executeMulti(update1)
            await execute(access3)
        }
        
        Task {
            access1.respond()
            access2.respond()
            refresh1.respond()
            update1.respond(index: 0)
            update1.respond(index: 1)
            access3.respond()
            
        }
        
        try! await Task.sleep(nanoseconds: 1_000_000_00)

        let theLog = await timeLogger.textLog()
        //print(theLog)
    }
    
}
