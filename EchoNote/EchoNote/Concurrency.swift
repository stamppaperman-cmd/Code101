import Foundation

/// Runs independent async pieces of work a few at a time and returns the results
/// in the original order. Ollama serves requests concurrently, so correcting or
/// summarizing chunk N does not need to wait for chunk N-1 to come back.
enum ConcurrentMap {
    static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        concurrency: Int,
        onWaveComplete: @Sendable (Int) -> Void = { _ in },
        transform: @escaping @Sendable (Int, Input) async throws -> Output
    ) async throws -> [Output?] {
        var results = [Output?](repeating: nil, count: inputs.count)
        guard !inputs.isEmpty else { return results }

        var start = 0
        var finished = 0
        while start < inputs.count {
            let end = min(start + max(concurrency, 1), inputs.count)
            let wave = try await withThrowingTaskGroup(of: (Int, Output).self) { group -> [(Int, Output)] in
                for index in start..<end {
                    let input = inputs[index]
                    group.addTask { (index, try await transform(index, input)) }
                }
                var collected = [(Int, Output)]()
                for try await item in group { collected.append(item) }
                return collected
            }
            for (index, value) in wave { results[index] = value }
            finished += wave.count
            onWaveComplete(finished)
            start = end
        }
        return results
    }
}
