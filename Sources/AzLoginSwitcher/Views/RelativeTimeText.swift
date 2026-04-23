import SwiftUI

/// Shows relative time like "2 min ago", "1 hr ago" — no seconds
struct RelativeTimeText: View {
    let date: Date
    @State private var now = Date()
    
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    
    var body: some View {
        Text(Self.formatter.localizedString(for: date, relativeTo: now))
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                now = Date()
            }
    }
}
