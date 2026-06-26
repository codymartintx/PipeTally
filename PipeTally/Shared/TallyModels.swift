import CoreGraphics
import Foundation

struct RecognizedToken: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var boundingBox: CGRect
    var confidence: Float
}

struct TallyRowDraft: Identifiable, Equatable {
    let id = UUID()
    var jointText: String
    var lengthText: String
    var rawLengthText: String
    var confidence: Float?
    var warnings: [String]

    var isBlank: Bool {
        lengthText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var confidenceText: String {
        guard let confidence else { return "" }
        return "\(Int((confidence * 100).rounded()))%"
    }
}

struct TallyStartJointDraft: Equatable {
    var text: String
    var rawText: String
    var confidence: Float?
    var warnings: [String]

    var needsReview: Bool {
        !warnings.isEmpty
    }

    var confidenceText: String {
        guard let confidence else { return "" }
        return "\(Int((confidence * 100).rounded()))%"
    }
}

struct TallyParseResult {
    var rows: [TallyRowDraft]
    var startJoint: TallyStartJointDraft
    var recognizedTokenCount: Int
    var pairedRowCount: Int
    var warnings: [String]
}

enum TallyLengthFormatter {
    static func displayLength(fromHundredths hundredths: Int) -> String {
        let feet = Double(hundredths) / 100.0
        return String(format: "%.2f'", feet)
    }

    static func parseHundredths(from text: String) -> Int? {
        let trimmed = text
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "ft", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains(".") {
            guard let value = Double(trimmed), value > 0 else { return nil }
            return Int((value * 100).rounded())
        }

        let digits = trimmed.filter(\.isNumber)
        guard let number = Int(digits), !digits.isEmpty else { return nil }

        if digits.count == 4 || digits.count == 5 {
            return number
        }

        if digits.count == 3, (240...480).contains(number) {
            return number * 10
        }

        return nil
    }
}
