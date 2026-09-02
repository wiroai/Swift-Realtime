import os
import XCTest
@testable import SwiftRealtime

final class PcmBufferingTests: XCTestCase {
    func testChunkerEmitsFixedChunksAndKeepsARemainder() {
        let chunker = PcmChunker(chunkSizeInBytes: 4)

        let first = chunker.add(Data([1, 2, 3]))
        let second = chunker.add(Data([4, 5, 6, 7, 8, 9]))

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])])
        XCTAssertEqual(chunker.remainderLength, 1)
    }

    func testBoundedQueuePreservesFIFOOrder() async {
        let queue = BoundedPcmQueue(capacityInChunks: 2)
        await queue.add(Data([1]))
        await queue.add(Data([2]))

        let first = await queue.take()
        let second = await queue.take()
        XCTAssertEqual(first, Data([1]))
        XCTAssertEqual(second, Data([2]))
    }

    func testBoundedQueueAppliesProducerBackpressure() async {
        let queue = BoundedPcmQueue(capacityInChunks: 1)
        await queue.add(Data([1]))
        let added = OSAllocatedUnfairLock(initialState: false)
        let secondAdd = Task {
            await queue.add(Data([2]))
            added.withLock { $0 = true }
        }

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(added.withLock { $0 })

        let first = await queue.take()
        XCTAssertEqual(first, Data([1]))
        await secondAdd.value
        XCTAssertTrue(added.withLock { $0 })
        let second = await queue.take()
        XCTAssertEqual(second, Data([2]))
    }

    func testBoundedQueueRefusesOverflowWithoutWaiting() async {
        let queue = BoundedPcmQueue(capacityInChunks: 1)

        XCTAssertTrue(queue.tryAdd(Data([1])))
        XCTAssertFalse(queue.tryAdd(Data([2])))

        XCTAssertEqual(queue.length, 1)
        let kept = await queue.take()
        XCTAssertEqual(kept, Data([1]))
    }

    func testClosingAQueueReleasesPendingConsumers() async {
        let queue = BoundedPcmQueue(capacityInChunks: 1)
        let pending = Task { await queue.take() }

        queue.close()

        let value = await pending.value
        XCTAssertNil(value)
        XCTAssertTrue(queue.isClosed)
    }
}
