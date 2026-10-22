// Floe: bound recycled GPU buffers after materialized PCM or a joined producer.
import Foundation
import MLX

extension Qwen3TTSModel {
    public static func reclaimGenerationCache() throws {
        try autoreleasepool {
            try MLX.withError { errors in
                MLX.Stream.gpu.synchronize()
                Memory.clearCache()
                try errors.check()
            }
        }
    }
}
