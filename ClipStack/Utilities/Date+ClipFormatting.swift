import Foundation

extension Date {
    /// Menu-friendly timestamp — hours and minutes only, no seconds.
    var clipMenuTimestamp: String {
        let calendar = Calendar.current

        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }

        if calendar.isDateInYesterday(self) {
            return "Yesterday, \(formatted(date: .omitted, time: .shortened))"
        }

        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }

        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
