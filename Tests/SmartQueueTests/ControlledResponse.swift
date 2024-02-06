
import Foundation
import XCTest

class ControlledResponse<T>:Identifiable {
    let id:UUID
    let response:T
    let expectation:XCTestExpectation
    let description:String
    var continuation:CheckedContinuation<T,Never>? = nil
    var continued:Bool
    var completed:Bool = false
    let logger:(String) -> ()
    
    init(response: T, description:String, continued:Bool = false, logger: @escaping (String) -> ()) {
        self.id = UUID()
        self.response = response
        let expectation = XCTestExpectation(description: description)
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true
        self.expectation = expectation
        self.description = description
        self.continued = continued
        self.logger = logger
    }
    
    func getResponse() async -> T {
        logger("Requested: \(self.description)")
        if self.continued {
            expectation.fulfill()
            self.completed = true
            logger("Responding auto: \(self.description)")
            return response
        } else {
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }
    
    func respond() {
        guard let continuation else {
            self.continued = true
            return
        }
        if self.continued == false {
            self.continued = true
            self.completed = true
            expectation.fulfill()
            logger("Responding triggered: \(self.description)")
            continuation.resume(returning: response)
            self.continuation = nil
        }
    }
}
