import Foundation
import AppKit

final class DefaultURLOpener: URLOpening, @unchecked Sendable {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
