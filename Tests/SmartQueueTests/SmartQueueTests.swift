@testable import SmartQueue
import XCTest

final class smart_queueTests: XCTestCase {
    enum OAuthError {
        case unauthorized
    }

    func testBasics() async throws {
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
                    return .updateDependency
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

    
    func testTricky() async throws {
        
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
                let retVal = self.responses[index]
                return self.responses[index]
            }
        }
        
        let uuidA = UUID()
        let uuidB = UUID()
        
        let responder = Responder(responses: [
            KnownResponse(response: .refresh(.success(uuidA)), description: "1 refresh"),
            KnownResponse(response: .task(.success("Hello 1")), description: "1 response"),
            KnownResponse(response: .task(.success("Hello 2")), description: "2 response"),
            KnownResponse(response: .task(.updateDependency), description: "1 update"),
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
    
    func testWhacky() async throws {

        class WonkyResponder {
            var access:Int
            var refreshThreads:Int
            
            init() {
                self.access = 0
                self.refreshThreads = 0
            }
            
            func refresh() async -> Int {
                try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<10_000))
                guard self.refreshThreads <= 1 else {
                    XCTFail("No more than one refresh thread is allowed at one time")
                    fatalError()
                }
                self.refreshThreads += 1
                defer {
                    self.refreshThreads -= 1
                }
                self.access += 1
                return self.access
            }
            
            func access(token:Int) async -> String? {
                try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<10_000))
                guard token == access else {
                    //print("Bad access \(token)")
                    return nil
                }
                //print("Good access \(token)")
                return "ac:\(token)"
            }
            
            func reset() async {
                try! await Task.sleep(nanoseconds: UInt64.random(in: 10..<10_000))
                //print("Reset \(access)")
                self.access += 1
            }
            
        }
        
        let wonky = WonkyResponder()
        
        let queue = SmartQueue<Int> { context in
            return await .success(wonky.refresh())
        }
        
        for _ in 0..<10000 {
            try! await Task.sleep(nanoseconds: UInt64.random(in: 1_0..<1_000_0))
            Task {
                if Int.random(in: 0..<10) < 3 {
                    await wonky.reset()
                } else {
                    let _ = await queue.run { token -> TaskResult<String> in
                        let retVal:String? = await wonky.access(token: token)
                        guard let retVal else {
                            return .updateDependency
                        }
                        return .success(retVal)
                    }
                }
            }
        }
        try! await Task.sleep(nanoseconds: 1_000_000)
        
    }
    
}
