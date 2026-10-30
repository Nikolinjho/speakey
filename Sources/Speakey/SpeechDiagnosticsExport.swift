import Foundation
import Darwin

/// Экспорт вызывается только явной CLI-командой. Ни микрофона, ни настроек приложения здесь нет.
enum SpeechDiagnosticsExport {
    enum Failure: Error { case invalidAudio, invalidArguments, outputExists, writeFailed }

    static func export(encrypted: URL, output: URL, keyProvider: @escaping () throws -> Data) throws {
        let store = SpeechDiagnosticsStore(directory: encrypted.deletingLastPathComponent(), enabled: false, keyProvider: keyProvider)
        let snapshot = try store.read(encrypted)
        guard snapshot.schema == 1, snapshot.sampleRate == 16000, snapshot.channels == 1,
              snapshot.pcmFormat == "IEEE754-float32-little-endian" else { throw Failure.invalidAudio }
        let wav = try SpeechFloatWAV.encode(pcm: snapshot.pcmFloat32LE)
        // mkdir атомарно отказывает для любой занятой цели, включая каталог или симлинк.
        guard Darwin.mkdir(output.path, mode_t(0o700)) == 0 else { throw Failure.outputExists }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        try writeNew(wav, to: output.appendingPathComponent("audio.wav"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeNew(try encoder.encode(snapshot), to: output.appendingPathComponent("trace.json"))
        let manifest: [String: Any] = [
            "id": snapshot.id.uuidString, "audio": "audio.wav", "reference": "",
            "reference_confirmed": false, "session_id": snapshot.id.uuidString,
            "split": "train", "language": "auto",
            "status": "draft_not_evaluable_until_human_reference_confirmation"
        ]
        var manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        manifestData.append(0x0a)
        try writeNew(manifestData, to: output.appendingPathComponent("manifest.jsonl"))
        complete = true
    }

    /// Файл получает 600 уже при создании. Hard link публикует целиком без перезаписи цели.
    static func writeNew(_ data: Data, to output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.outputExists }
        let staged = output.deletingLastPathComponent().appendingPathComponent(".speech-pending-" + UUID().uuidString)
        let fd = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw Failure.writeFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staged) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.linkItem(at: staged, to: output)
    }
}

/// Экспорт IEEE float32 LE без потерь. Чтение также принимает PCM8/16/24/32 mono 16 kHz.
/// Целый PCM нормируется делением на 2^(bits-1), PCM8 сначала сдвигается на -128.
enum SpeechFloatWAV {
    // Ограничение до копирования входа и выделения массива сэмплов: около 70 минут float32.
    static let maximumByteCount = 256 * 1024 * 1024
    static func encode(pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 4 == 0, pcm.count <= maximumByteCount - 44 else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let finite = pcm.withUnsafeBytes { bytes in
            stride(from: 0, to: pcm.count, by: 4).allSatisfy { offset in
                let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                return Float(bitPattern: bits).isFinite
            }
        }
        guard finite else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        var data = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(3), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(16000), to: &data)
        append(UInt32(64000), to: &data)
        append(UInt16(4), to: &data)
        append(UInt16(32), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    static func read(_ data: Data) throws -> [Float] {
        guard data.count <= maximumByteCount else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        func tag(_ offset: Int, _ value: String) -> Bool {
            Array(bytes[offset..<(offset + 4)]) == Array(value.utf8)
        }
        guard bytes.count >= 12, tag(0, "RIFF"), tag(8, "WAVE"),
              UInt64(number(4, 4)) + 8 == UInt64(bytes.count) else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        var offset = 12
        var format: UInt32?
        var bits = 0
        var blockAlign = 0
        var pcm: Range<Int>?
        while offset < bytes.count {
            guard offset <= bytes.count - 8 else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
            let size = Int(number(offset + 4, 4))
            let start = offset + 8
            guard size <= bytes.count - start else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
            if tag(offset, "fmt ") {
                guard size >= 16 else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
                let tag = number(start, 2)
                bits = Int(number(start + 14, 2))
                blockAlign = bits / 8
                guard format == nil, (size == 16 || (size == 18 && number(start + 16, 2) == 0)),
                      number(start + 2, 2) == 1, number(start + 4, 4) == 16000,
                      (tag == 3 && bits == 32) || (tag == 1 && [8, 16, 24, 32].contains(bits)),
                      number(start + 8, 4) == UInt32(16000 * blockAlign),
                      number(start + 12, 2) == UInt32(blockAlign) else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
                format = tag
            } else if tag(offset, "data") {
                guard pcm == nil, size > 0 else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
                pcm = start..<(start + size)
            }
            offset = start + size + (size % 2)
            guard offset <= bytes.count else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        }
        guard let format, let pcm, blockAlign > 0, pcm.count % blockAlign == 0 else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let samples = stride(from: pcm.lowerBound, to: pcm.upperBound, by: blockAlign).map { index -> Float in
            let raw = number(index, blockAlign)
            if format == 3 { return Float(bitPattern: raw) }
            if bits == 8 { return Float(Int(raw) - 128) / 128 }
            let signed = Int32(bitPattern: raw << (32 - bits)) >> (32 - bits)
            return Float(signed) / Float(UInt64(1) << (bits - 1))
        }
        guard samples.allSatisfy(\.isFinite) else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        return samples
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

struct SpeechCLIArguments {
    let command: String
    let engine: String
    let input: URL
    let output: URL
    let model: URL?
    let language: String?

    static func parse(_ arguments: [String]) throws -> Self {
        guard let command = arguments.first, ["export", "transcribe"].contains(command), arguments.count % 2 == 1 else {
            throw SpeechDiagnosticsExport.Failure.invalidArguments
        }
        let required: Set<String> = command == "export" ? ["--input", "--output"] : ["--input", "--output", "--model", "--language"]
        let allowed = command == "export" ? required : required.union(["--engine"])
        var values: [String: String] = [:]
        for index in stride(from: 1, to: arguments.count, by: 2) {
            let name = arguments[index], value = arguments[index + 1]
            guard allowed.contains(name), values[name] == nil, !value.isEmpty else { throw SpeechDiagnosticsExport.Failure.invalidArguments }
            values[name] = value
        }
        guard required.isSubset(of: Set(values.keys)), let input = values["--input"], let output = values["--output"] else {
            throw SpeechDiagnosticsExport.Failure.invalidArguments
        }
        if command == "transcribe", !["ru", "en", "auto"].contains(values["--language"] ?? "") {
            throw SpeechDiagnosticsExport.Failure.invalidArguments
        }
        let engine = values["--engine"] ?? "whisper"
        guard ["whisper", "parakeet"].contains(engine) else { throw SpeechDiagnosticsExport.Failure.invalidArguments }
        return Self(command: command, engine: engine, input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output),
                    model: values["--model"].map { URL(fileURLWithPath: $0) }, language: values["--language"])
    }
}
