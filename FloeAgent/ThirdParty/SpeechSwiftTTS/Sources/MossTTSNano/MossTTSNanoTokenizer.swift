import Foundation

/// SentencePiece BPE with the checkpoint's compiled normalization map and byte fallback.
/// Uses UTF-8 bytes for vocabulary identity, preserving distinct Unicode scalar sequences.
struct MossTTSNanoTokenizer: Sendable {
    struct Piece: Decodable, Sendable { let text: String; let score: Float; let type: Int }
    struct Archive: Decodable {
        let format: String
        let pieces: [Piece]
        let precompiled_charsmap: Data
    }
    private let pieces: [Piece]
    private let vocabulary: [Data: Int]
    private let userDefined: [Data]
    private let byteIDs: [Int]
    private let trie: [UInt32]
    private let normalized: [UInt8]

    init(data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.format == "moss_sentencepiece_bpe_v1", archive.pieces.count == 16384,
              archive.pieces.allSatisfy({ !$0.text.isEmpty && $0.score.isFinite }),
              archive.precompiled_charsmap.count > 4 else {
            throw MossTTSNanoError.invalidConfiguration("invalid tokenizer archive")
        }
        pieces = archive.pieces
        var vocab: [Data: Int] = [:], bytes = [Int](repeating: -1, count: 256)
        for (index, piece) in pieces.enumerated() {
            if piece.type == 1 || piece.type == 4 { vocab[Data(piece.text.utf8)] = index }
            if piece.type == 6, piece.text.hasPrefix("<0x"), piece.text.hasSuffix(">"),
               let byte = Int(piece.text.dropFirst(3).dropLast(), radix: 16), bytes.indices.contains(byte) { bytes[byte] = index }
        }
        guard bytes.allSatisfy({ $0 >= 0 }) else { throw MossTTSNanoError.invalidConfiguration("missing byte fallback") }
        vocabulary = vocab; byteIDs = bytes
        userDefined = pieces.filter { $0.type == 4 }.map { Data($0.text.utf8) }.sorted { $0.count > $1.count }
        let map = archive.precompiled_charsmap
        let size = Int(map.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard size >= 1024, size % 1024 == 0, size < map.count - 4, map.last == 0 else {
            throw MossTTSNanoError.invalidConfiguration("invalid normalization trie")
        }
        trie = stride(from: 4, to: 4 + size, by: 4).map { offset in
            map.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        normalized = Array(map[(4 + size)...])
    }

    private func scalarLength(_ first: UInt8) -> Int { first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4 }
    private func special(_ input: [UInt8], _ start: Int) -> Data? {
        guard input[start] == 60 else { return nil }
        return userDefined.first { input[start...].starts(with: $0) }
    }
    private func prefix(_ input: [UInt8], _ start: Int) throws -> (bytes: [UInt8], count: Int) {
        if let token = special(input, start) { return (Array(token), token.count) }
        func offset(_ unit: UInt32) -> Int { Int((unit >> 10) << ((unit & 512) >> 6)) }
        var node = offset(trie[0]), length = 0, value = 0
        for index in start..<input.count {
            node ^= Int(input[index])
            guard trie.indices.contains(node) else { throw MossTTSNanoError.invalidConfiguration("normalizer trie offset") }
            let unit = trie[node]
            if unit & 0x800000ff != UInt32(input[index]) { break }
            node ^= offset(unit)
            if unit & 256 != 0 {
                guard trie.indices.contains(node) else { throw MossTTSNanoError.invalidConfiguration("normalizer leaf offset") }
                length = index - start + 1; value = Int(trie[node] & 0x7fffffff)
            }
        }
        if length == 0 {
            let count = scalarLength(input[start])
            return (Array(input[start..<(start + count)]), count)
        }
        guard normalized.indices.contains(value), let end = normalized[value...].firstIndex(of: 0) else {
            throw MossTTSNanoError.invalidConfiguration("normalizer string offset")
        }
        return (Array(normalized[value..<end]), length)
    }

    func normalize(_ text: String) throws -> [UInt8] {
        let input = Array(text.utf8), space: [UInt8] = [0xe2, 0x96, 0x81]
        guard input.count <= 32768 else { throw MossTTSNanoError.invalidInput("text exceeds 32 KiB") }
        var start = 0
        while start < input.count {
            let part = try prefix(input, start)
            if part.bytes != [32] { break }
            start += part.count
        }
        if start == input.count { return [] }
        var output = space, previousSpace = true
        while start < input.count {
            let part = try prefix(input, start)
            var content = part.bytes[...]
            while previousSpace && content.first == 32 { content = content.dropFirst() }
            if !content.isEmpty {
                for byte in content { if byte == 32 { output += space } else { output.append(byte) } }
                previousSpace = content.last == 32
            }
            start += part.count
        }
        while output.suffix(3).elementsEqual(space) { output.removeLast(3) }
        return output
    }

    func encode(_ text: String) throws -> [Int32] {
        let input = try normalize(text)
        if input.isEmpty { return [] }
        struct Symbol { var bytes: Data; var previous: Int; var next: Int; let frozen: Bool }
        struct Pair {
            let left: Int; let right: Int; let size: Int; let score: Float
            func precedes(_ other: Pair) -> Bool { score == other.score ? left < other.left : score > other.score }
        }
        var symbols: [Symbol] = [], position = 0
        while position < input.count {
            let token = special(input, position)
            let size = token?.count ?? scalarLength(input[position])
            symbols.append(Symbol(bytes: Data(input[position..<(position + size)]), previous: symbols.count - 1,
                                  next: position + size == input.count ? -1 : symbols.count + 1, frozen: token != nil))
            position += size
        }
        var heap: [Pair] = []
        func push(_ pair: Pair) {
            heap.append(pair)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                if !heap[index].precedes(heap[parent]) { break }
                heap.swapAt(index, parent); index = parent
            }
        }
        func pop() -> Pair? {
            if heap.isEmpty { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]; heap[0] = heap.removeLast()
            var index = 0
            while index * 2 + 1 < heap.count {
                var child = index * 2 + 1
                if child + 1 < heap.count && heap[child + 1].precedes(heap[child]) { child += 1 }
                if !heap[child].precedes(heap[index]) { break }
                heap.swapAt(child, index); index = child
            }
            return first
        }
        func enqueue(_ left: Int) {
            guard left >= 0 else { return }
            let right = symbols[left].next
            guard right >= 0, !symbols[left].frozen, !symbols[right].frozen,
                  let id = vocabulary[symbols[left].bytes + symbols[right].bytes] else { return }
            push(Pair(left: left, right: right, size: symbols[left].bytes.count + symbols[right].bytes.count, score: pieces[id].score))
        }
        for index in symbols.indices { enqueue(index) }
        while let pair = pop() {
            guard symbols[pair.left].next == pair.right, !symbols[pair.left].bytes.isEmpty, !symbols[pair.right].bytes.isEmpty,
                  pair.size == symbols[pair.left].bytes.count + symbols[pair.right].bytes.count else { continue }
            symbols[pair.left].bytes += symbols[pair.right].bytes
            symbols[pair.right].bytes = Data()
            let next = symbols[pair.right].next
            symbols[pair.left].next = next
            if next >= 0 { symbols[next].previous = pair.left }
            enqueue(symbols[pair.left].previous); enqueue(pair.left)
        }
        return symbols.filter { !$0.bytes.isEmpty }.flatMap { symbol -> [Int32] in
            if let id = vocabulary[symbol.bytes] { return [Int32(id)] }
            return symbol.bytes.map { Int32(byteIDs[Int($0)]) }
        }
    }

    func prompt(text: String, reference: MossTTSNanoReference? = nil) throws -> [[Int32]] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MossTTSNanoError.invalidInput("text must not be empty")
        }
        func rows(_ ids: [Int32]) -> [[Int32]] { ids.map { [$0] + [Int32](repeating: 1024, count: 16) } }
        var result = rows([4] + (try encode("user\n")) + (try encode("<user_inst>\n- Reference(s):\n")))
        if let reference {
            result += rows([6]); result += reference.codes.map { [8] + $0 }; result += rows([7])
        } else { result += rows(try encode("None")) }
        result += rows(try encode("\n- Instruction:\nNone\n- Tokens:\nNone\n- Quality:\nNone\n- Sound Event:\nNone\n- Ambient Sound:\nNone\n- Language:\nNone\n- Text:\n"))
        result += rows(try encode(text)); result += rows(try encode("\n</user_inst>"))
        result += rows([5] + (try encode("\n")) + [4] + (try encode("assistant\n")) + [6])
        return result
    }
}
