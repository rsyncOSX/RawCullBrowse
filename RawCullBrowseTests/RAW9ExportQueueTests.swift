import Foundation
@testable import RawCullBrowse
import Testing

private actor ExportProbe {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completionWaiter: CheckedContinuation<Void, Never>?

    func run(_ job: RAW9ExportJob) async throws {
        let name = job.destination.lastPathComponent
        started.append(name)
        if started.count == 1 {
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        finished.append(name)
        if name == "fail" {
            throw CocoaError(.fileWriteUnknown)
        }
        if name == "last" {
            completionWaiter?.resume()
            completionWaiter = nil
        }
    }

    func waitForStart() async {
        if releaseFirst != nil {
            return
        }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func waitForCompletion() async {
        if finished.contains("last") {
            return
        }
        await withCheckedContinuation { completionWaiter = $0 }
    }
}

@Suite("RAW 9 background export queue", .timeLimit(.minutes(1)))
struct RAW9ExportQueueTests {
    private func job(_ name: String) -> RAW9ExportJob {
        RAW9ExportJob(source: URL(fileURLWithPath: "/tmp/source.ARW"),
                      adjustments: RAW9Adjustments(exposure: 1),
                      destination: URL(fileURLWithPath: "/tmp/" + name), type: "public.png")
    }

    @Test @MainActor func `exports added during active work run in FIFO order after failures`() async {
        let probe = ExportProbe()
        let queue = RAW9ExportQueue(operation: { try await probe.run($0) })
        queue.enqueue(job("first"))
        await probe.waitForStart()
        queue.enqueue(job("fail"))
        queue.enqueue(job("last"))
        #expect(queue.waitingCount == 2)
        #expect(queue.outstandingCount == 3)
        #expect(await probe.started == ["first"])
        await probe.release()
        await queue.waitUntilFinished()
        #expect(await probe.started == ["first", "fail", "last"])
        #expect(await probe.finished == ["first", "fail", "last"])
        #expect(queue.outstandingCount == 0)
        #expect(queue.lastError?.contains("fail") == true)
    }

    @Test @MainActor func `closing the requester does not discard accepted exports`() async {
        let probe = ExportProbe()
        var queue: RAW9ExportQueue? = RAW9ExportQueue(operation: { try await probe.run($0) })
        weak let retainedQueue = queue
        queue?.enqueue(job("first"))
        queue?.enqueue(job("last"))
        await probe.waitForStart()
        queue = nil
        #expect(retainedQueue != nil)
        await probe.release()
        await probe.waitForCompletion()
        #expect(await probe.finished == ["first", "last"])
    }

    @Test @MainActor func `canceling a caller does not cancel queued exports`() async {
        let probe = ExportProbe()
        let queue = RAW9ExportQueue(operation: { try await probe.run($0) })
        let caller = Task {
            queue.enqueue(job("first"))
            queue.enqueue(job("last"))
            await queue.waitUntilFinished()
        }
        await probe.waitForStart()
        caller.cancel()
        await probe.release()
        await caller.value
        #expect(await probe.finished == ["first", "last"])
        #expect(queue.outstandingCount == 0)
        #expect(queue.lastError == nil)
    }
}
