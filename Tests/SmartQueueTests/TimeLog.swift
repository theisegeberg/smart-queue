
import Foundation

extension Date {
    func timeWithMilliseconds() -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: self)
        let minute = calendar.component(.minute, from: self)
        let second = calendar.component(.second, from: self)
        let nanosecond = calendar.component(.nanosecond, from: self)
        let microseconds = nanosecond / 1_000
        
        return String(format: "%02d:%02d:%02d.%03d", hour, minute, second, microseconds)
    }
}

actor TimeLog {
    
    struct Entry:ExpressibleByStringLiteral {
        let time:Date
        let text:String
        
        init(time:Date, text:String) {
            self.time = time
            self.text = text
        }
        
        init(stringLiteral value: StringLiteralType) {
            self.init(time: .now, text: value)
        }
    }
    
    var entries:[Entry] = []
    
    func add(_ entry:Entry) {
        self.entries.append(entry)
    }
    
    func add(_ entry:String) {
        self.entries.append(.init(stringLiteral: entry))
    }
    
    func orderedEntries() -> [Entry] {
        self.entries.sorted { a, b in
            a.time < b.time
        }
    }
    
    func textLog() -> String {
        self.orderedEntries().map { entry in
            "\(entry.time.timeWithMilliseconds()): \(entry.text)"
        }.joined(separator: "\n")
    }
}
