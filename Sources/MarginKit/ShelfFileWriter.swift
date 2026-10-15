import Dispatch
import Foundation
import os

/// shelf.json's writes, off the main actor, one at a time on a serial queue. A write asked for while another is
/// still waiting to start replaces what that one will write, so a burst of changes (a folder of moved files, captures
/// in quick succession) costs a write or two, and the file always ends up with the newest list.
final class ShelfFileWriter: Sendable {
    typealias Report = @Sendable (_ milliseconds: Double, _ bytes: Int) -> Void

    let fileURL: URL
    private let queue: DispatchQueue
    /// The newest list not taken by a write yet, and whom to tell when it's written.
    private let next = OSAllocatedUnfairLock<(items: [ShelfItem], report: Report)?>(initialState: nil)

    /// `queue` must be serial. The save pipeline waits for these writes before writing a PNG, so they run at its
    /// priority.
    init(fileURL: URL, queue: DispatchQueue = DispatchQueue(label: "io.github.jenish-shobhit.margin.shelf-json", qos: .userInitiated)) {
        self.fileURL = fileURL
        self.queue = queue
    }

    /// Hands `items` over to be written, and returns at once. `report` runs on the queue after the write.
    func write(_ items: [ShelfItem], report: @escaping Report) {
        let waiting = next.withLock { next in
            defer { next = (items, report) }
            return next != nil
        }
        // A write that hasn't started yet takes this list instead of its own.
        guard !waiting else { return }
        queue.async { [self] in
            guard let job = next.withLock({ next in
                defer { next = nil }
                return next
            }) else { return }
            let start = ContinuousClock.now
            guard let bytes = ShelfStore.write(job.items, to: fileURL) else { return }
            job.report(ShelfStore.milliseconds(since: start), bytes)
        }
    }

    /// Blocks until everything handed over so far is written.
    func flush() {
        queue.sync {}
    }

    /// Returns once everything handed over before the call is written.
    func written() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }
}
