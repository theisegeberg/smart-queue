
import Foundation
import XCTest

class ControlledResponse<T>:Identifiable {
    let id:UUID
    let response:T
    let description:String
    var continuation:CheckedContinuation<T,Never>? = nil
    var continued:Bool
    let logger:(String) -> ()
    
    init(response: T, description:String, continued:Bool = false, logger: @escaping (String) -> ()) {
        self.id = UUID()
        self.response = response
//        let expectation = XCTestExpectation(description: description)
//        expectation.expectedFulfillmentCount = 1
//        expectation.assertForOverFulfill = true
//        self.expectation = expectation
        self.description = description
        self.continued = continued
        self.logger = logger
    }
    
    func getResponse() async -> T {
        logger("Requested: \(self.description)")
        if self.continued {
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
            logger("Responding triggered: \(self.description)")
            continuation.resume(returning: response)
            self.continuation = nil
            self.continued = false
        }
    }
}
