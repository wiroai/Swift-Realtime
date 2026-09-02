import Foundation
import os

/// Re-frames arbitrary PCM byte runs into fixed-size chunks.
///
/// `add` runs on the capture thread while `reset` is called from the
/// recorder's task on mute or stop, so the carried remainder lives
/// under a lock.
final class PcmChunker: @unchecked Sendable {
    let chunkSizeInBytes: Int
    private let remainder = OSAllocatedUnfairLock(initialState: Data())

    var remainderLength: Int {
        remainder.withLock(\.count)
    }

    init(chunkSizeInBytes: Int) {
        precondition(chunkSizeInBytes > 0, "Chunk size must be positive.")
        self.chunkSizeInBytes = chunkSizeInBytes
    }

    func add(_ bytes: Data) -> [Data] {
        guard !bytes.isEmpty else {
            return []
        }
        return remainder.withLock { remainder in
            var combined = remainder
            combined.append(bytes)
            var chunks: [Data] = []
            var offset = 0
            while combined.count - offset >= chunkSizeInBytes {
                let end = offset + chunkSizeInBytes
                chunks.append(combined.subdata(in: offset..<end))
                offset = end
            }
            remainder = combined.subdata(in: offset..<combined.count)
            return chunks
        }
    }

    func reset() {
        remainder.withLock { $0 = Data() }
    }
}
