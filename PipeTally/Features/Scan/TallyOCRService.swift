import UIKit
import Vision

enum TallyOCRService {
    static func recognizeTokens(in image: UIImage) async throws -> [RecognizedToken] {
        let preparedImage = image.preparedForOCR()
        guard let cgImage = preparedImage.cgImage else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            var tokens: [RecognizedToken] = []

            for tile in recognitionTiles(for: imageSize) {
                guard let tileImage = cgImage.cropping(to: tile) else { continue }
                let observations = try recognizeText(in: tileImage)

                tokens += observations.flatMap { observation -> [RecognizedToken] in
                    guard let candidate = observation.topCandidates(1).first else { return [] }
                    let mappedBox = map(observation.boundingBox, from: tile, imageSize: imageSize)
                    return splitNumericTokens(
                        in: candidate.string,
                        boundingBox: mappedBox,
                        confidence: candidate.confidence
                    )
                }
            }

            return mergeDuplicateTokens(tokens)
        }.value
    }

    private static func recognizeText(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.002

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        return request.results ?? []
    }

    private static func recognitionTiles(for imageSize: CGSize) -> [CGRect] {
        let fullRect = CGRect(origin: .zero, size: imageSize)
        guard imageSize.width >= 900, imageSize.height >= 900 else {
            return [fullRect]
        }

        let columnCount = imageSize.width > imageSize.height ? 6 : 4
        let overlap = imageSize.width * 0.025
        let baseWidth = imageSize.width / CGFloat(columnCount)

        let columns = (0..<columnCount).map { index in
            let minX = max(CGFloat(index) * baseWidth - overlap, 0)
            let maxX = min(CGFloat(index + 1) * baseWidth + overlap, imageSize.width)
            return CGRect(x: minX, y: 0, width: maxX - minX, height: imageSize.height)
        }

        return [fullRect] + columns + printableSheetTiles(for: imageSize)
    }

    private static func printableSheetTiles(for imageSize: CGSize) -> [CGRect] {
        guard imageSize.width > imageSize.height else { return [] }

        let page = PrintableSheetOCRGeometry.pageRect(in: imageSize)
        let columnStride = PrintableSheetOCRGeometry.columnWidth + PrintableSheetOCRGeometry.columnGap
        var tiles: [CGRect] = []

        for column in 0..<5 {
            let columnX = PrintableSheetOCRGeometry.marginX + CGFloat(column) * columnStride
            let writeX = columnX + PrintableSheetOCRGeometry.jointWidth
            let writeWidth = PrintableSheetOCRGeometry.feetWidth + PrintableSheetOCRGeometry.hundredthsWidth

            for block in 0..<2 {
                let blockTop = PrintableSheetOCRGeometry.rowTopY
                    - CGFloat(block) * (PrintableSheetOCRGeometry.rowHeight * 10 + PrintableSheetOCRGeometry.blockGap)
                let blockBottom = blockTop - PrintableSheetOCRGeometry.rowHeight * 10
                let pdfRect = CGRect(
                    x: writeX - 7,
                    y: blockBottom - 5,
                    width: writeWidth + 14,
                    height: blockTop - blockBottom + 10
                )

                tiles.append(PrintableSheetOCRGeometry.imageRect(fromPDFRect: pdfRect, page: page))
            }
        }

        tiles.append(PrintableSheetOCRGeometry.imageRect(
            fromPDFRect: PrintableSheetOCRGeometry.startJointPDFRect,
            page: page
        ))

        return tiles
    }

    private static func map(_ box: CGRect, from tile: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: (tile.minX + box.minX * tile.width) / imageSize.width,
            y: (imageSize.height - tile.maxY + box.minY * tile.height) / imageSize.height,
            width: box.width * tile.width / imageSize.width,
            height: box.height * tile.height / imageSize.height
        )
    }

    private static func mergeDuplicateTokens(_ tokens: [RecognizedToken]) -> [RecognizedToken] {
        var merged: [RecognizedToken] = []

        for token in tokens.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicateIndex = merged.firstIndex { existing in
                existing.text == token.text
                    && abs(existing.boundingBox.midX - token.boundingBox.midX) < 0.010
                    && abs(existing.boundingBox.midY - token.boundingBox.midY) < 0.010
            }

            if duplicateIndex == nil {
                merged.append(token)
            }
        }

        return merged
    }

    private static func splitNumericTokens(
        in text: String,
        boundingBox: CGRect,
        confidence: Float
    ) -> [RecognizedToken] {
        let normalizedText = normalizedOCRDigits(in: text)
        let collapsedDigits = normalizedText.digits
        if let collapsedLength = TallyLengthFormatter.parseHundredths(from: collapsedDigits),
           (1_800...5_000).contains(collapsedLength),
           normalizedText.hasRealDigit,
           text.count <= 10 {
            return [
                RecognizedToken(
                    text: collapsedDigits,
                    boundingBox: boundingBox,
                    confidence: confidence
                )
            ]
        }

        let pattern = #"[0-9OoSsIl|]+(?:\.[0-9OoSsIl|]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        return matches.compactMap { match in
            let raw = nsText.substring(with: match.range)
            let normalizedRaw = normalizedOCRDigits(in: raw)
            guard normalizedRaw.hasRealDigit, !normalizedRaw.digits.isEmpty else { return nil }

            let startRatio = CGFloat(match.range.location) / CGFloat(max(nsText.length, 1))
            let widthRatio = CGFloat(match.range.length) / CGFloat(max(nsText.length, 1))
            let tokenBox = CGRect(
                x: boundingBox.minX + boundingBox.width * startRatio,
                y: boundingBox.minY,
                width: max(boundingBox.width * widthRatio, 0.002),
                height: boundingBox.height
            )

            return RecognizedToken(text: raw, boundingBox: tokenBox, confidence: confidence)
        }
    }

    private static func normalizedOCRDigits(in text: String) -> (digits: String, hasRealDigit: Bool) {
        var digits = ""
        var hasRealDigit = false

        for character in text {
            if character.isNumber {
                digits.append(character)
                hasRealDigit = true
                continue
            }

            switch character {
            case "O", "o":
                digits.append("0")
            case "I", "l", "|":
                digits.append("1")
            case "S", "s":
                digits.append("5")
            default:
                continue
            }
        }

        return (digits, hasRealDigit)
    }
}

private enum PrintableSheetOCRGeometry {
    static let pageWidth = CGFloat(792)
    static let pageHeight = CGFloat(612)
    static let marginX = CGFloat(25.2)
    static let columnWidth = CGFloat(141.408)
    static let columnGap = CGFloat(8.64)
    static let jointWidth = CGFloat(28.8)
    static let feetWidth = CGFloat(41.76)
    static let hundredthsWidth = CGFloat(47.52)
    static let rowTopY = CGFloat(521.28)
    static let rowHeight = CGFloat(25.866)
    static let blockGap = CGFloat(5.4)
    static let startJointPDFRect = CGRect(x: 570, y: 532, width: 210, height: 68)

    static func pageRect(in imageSize: CGSize) -> CGRect {
        CGRect(
            x: imageSize.width * 0.015,
            y: imageSize.height * 0.015,
            width: imageSize.width * 0.97,
            height: imageSize.height * 0.97
        )
    }

    static func imageRect(fromPDFRect pdfRect: CGRect, page: CGRect) -> CGRect {
        let clampedPDFRect = pdfRect.intersection(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let minX = page.minX + clampedPDFRect.minX / pageWidth * page.width
        let maxX = page.minX + clampedPDFRect.maxX / pageWidth * page.width
        let minY = page.minY + (1 - clampedPDFRect.maxY / pageHeight) * page.height
        let maxY = page.minY + (1 - clampedPDFRect.minY / pageHeight) * page.height

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).integral
    }
}

private extension UIImage {
    func preparedForOCR() -> UIImage {
        let longestSide = max(size.width, size.height)
        let needsScaling = longestSide < 1_000
        let needsOrientationNormalization = imageOrientation != .up

        guard needsScaling || needsOrientationNormalization else {
            return self
        }

        let scaleFactor = needsScaling ? 1_800 / longestSide : 1
        let targetSize = CGSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .down:
            self = .down
        case .left:
            self = .left
        case .right:
            self = .right
        case .upMirrored:
            self = .upMirrored
        case .downMirrored:
            self = .downMirrored
        case .leftMirrored:
            self = .leftMirrored
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
