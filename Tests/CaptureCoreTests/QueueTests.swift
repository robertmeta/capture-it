import XCTest
@testable import CaptureCore

final class QueueTests: XCTestCase {
    func testBoundedFIFOAndDrainAfterClose() {
        let queue = AudioQueue<Int>(capacity: 2)
        XCTAssertTrue(queue.offer(1)); XCTAssertTrue(queue.offer(2))
        XCTAssertFalse(queue.offer(3))
        queue.finish()
        XCTAssertEqual(queue.take(), 1); XCTAssertEqual(queue.take(), 2)
        XCTAssertNil(queue.take()); XCTAssertFalse(queue.offer(4))
    }

    func testConcurrentProducerAndConsumerPreserveOrder() {
        let queue = AudioQueue<Int>(capacity: 64)
        let consumer = expectation(description: "consumer")
        DispatchQueue.global().async {
            var expected = 0
            while let value = queue.take() { XCTAssertEqual(value, expected); expected += 1 }
            XCTAssertEqual(expected, 20_000)
            consumer.fulfill()
        }
        for index in 0 ..< 20_000 {
            while !queue.offer(index) { Thread.sleep(forTimeInterval: 0.0001) }
        }
        queue.finish()
        wait(for: [consumer], timeout: 10)
    }
}
