
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


class ControlledMultiResponse<T>:Identifiable {
    
    struct IdentifiedResponse:Identifiable {
        let id:UUID = .init()
        var responded:Bool = false
        var continuation:CheckedContinuation<T,Never>? = nil
        let value:T
        init(value: T) {
            self.value = value
        }
    }
    
    let id:UUID
    var responses:[IdentifiedResponse]
    let description:String
    let logger:(String) -> ()
    var internalResponseCounter:Int = 0
    
    init(description:String, responses:[IdentifiedResponse], logger: @escaping (String) -> ()) {
        self.id = UUID()
        self.description = description
        self.logger = logger
        self.responses = responses
    }
    
    func getResponse() async -> T {
        logger("Requested: \(self.description) \(internalResponseCounter)")
        var response = self.responses[internalResponseCounter]
        if response.responded {
            logger("Responding: \(self.description) \(internalResponseCounter)")
            defer {
                self.internalResponseCounter += 1
            }
            return response.value
        } else {
            logger("Queueing: \(self.description) \(internalResponseCounter)")
            return await withCheckedContinuation { continuation in
                response.continuation = continuation
                self.responses[internalResponseCounter] = response
            }
        }
    }
    
    func respond(index:Int) {
        logger("Response triggered: \(self.description) \(index)")

        var copy = self.responses[index]
        if copy.responded {
            // do nothing
        } else if copy.continuation == nil, copy.responded == false {
            copy.responded = true
        } else if let continuation = copy.continuation, copy.responded == false {
            continuation.resume(returning: copy.value)
            copy.responded = true
            copy.continuation = nil
        } else {
            fatalError()
        }
        self.responses[index] = copy
    }
}
