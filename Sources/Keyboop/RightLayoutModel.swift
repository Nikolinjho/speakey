import CoreML
import Foundation

enum RightLayoutTokenizer {
    private static let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890 -=[]\\;',./`!@#$%^&*()_+{}|:\"<>?~"
        + "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
        + "אבגדהוזחטיכלמנסעפצקרשתךםןףץ"
    private static let indices = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map {
        ($0.element, Int32($0.offset + 1))
    })
    static let inputLength = 20

    static func encode(_ word: String) throws -> [Int32] {
        guard !word.isEmpty, word.count <= inputLength,
              !word.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw NeuralLayoutError.invalidToken
        }
        let encoded = word.map { indices[$0, default: 0] }
        return encoded + Array(repeating: 0, count: inputLength - encoded.count)
    }
}

final class RightLayoutModel: NeuralLayoutBackend {
    private let model: MLModel

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw NeuralLayoutError.unavailable
        }
        let description = model.modelDescription
        guard description.inputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName["input_ids"],
              let output = description.outputDescriptionsByName["classLogits"] else {
            throw NeuralLayoutError.invalidOutput
        }
        try Self.validateArray(type: input.type, dataType: input.multiArrayConstraint?.dataType,
                               shape: input.multiArrayConstraint?.shape.map(\.intValue) ?? [], isInput: true)
        // Экспорт не объявляет форму выхода, поэтому фактическую форму проверяем при каждом прогнозе.
        try Self.validateArray(type: output.type, dataType: output.multiArrayConstraint?.dataType,
                               shape: output.multiArrayConstraint?.shape.map(\.intValue) ?? [], isInput: false, allowUnspecifiedShape: true)
    }

    static func validateArray(type: MLFeatureType, dataType: MLMultiArrayDataType?, shape: [Int], isInput: Bool, allowUnspecifiedShape: Bool = false) throws {
        guard type == .multiArray else { throw NeuralLayoutError.invalidOutput }
        if isInput {
            guard dataType == .float32, shape == [1, RightLayoutTokenizer.inputLength] else {
                throw NeuralLayoutError.invalidOutput
            }
        } else {
            guard dataType == .float32,
                  shape == [9] || shape == [1, 9] || (allowUnspecifiedShape && shape.isEmpty) else {
                throw NeuralLayoutError.invalidOutput
            }
        }
    }

    func predict(_ word: String) throws -> NeuralLayoutScores {
        let ids = try RightLayoutTokenizer.encode(word)
        do {
            // Модель объявляет Float32, но принимает исходные int32 ID через преобразование Core ML.
            let input = try MLMultiArray(shape: [1, NSNumber(value: RightLayoutTokenizer.inputLength)], dataType: .int32)
            for (index, value) in ids.enumerated() {
                input[index] = NSNumber(value: value)
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input])
            let prediction = try model.prediction(from: features)
            guard let output = prediction.featureValue(for: "classLogits"), let logits = output.multiArrayValue else {
                throw NeuralLayoutError.invalidOutput
            }
            try Self.validateArray(type: output.type, dataType: logits.dataType,
                                   shape: logits.shape.map(\.intValue), isInput: false)
            return try NeuralLayoutScores(logits: (0..<logits.count).map { logits[$0].doubleValue })
        } catch let error as NeuralLayoutError {
            throw error
        } catch {
            throw NeuralLayoutError.invalidOutput
        }
    }
}
