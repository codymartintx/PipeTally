import CoreGraphics
import Foundation

enum TallyParser {
    private struct NumericToken {
        var token: RecognizedToken
        var integerValue: Int?
        var lengthHundredths: Int?
        var normalizedDigitCount: Int
        var midX: CGFloat { token.boundingBox.midX }
        var midY: CGFloat { token.boundingBox.midY }
        var height: CGFloat { token.boundingBox.height }
        var digitCount: Int { normalizedDigitCount }
    }

    private struct Pair {
        var jointNumber: Int
        var lengthHundredths: Int
        var rawLengthText: String
        var confidence: Float
        var x: CGFloat
        var y: CGFloat
        var lengthID: UUID
        var inferredFromGrid: Bool
    }

    private struct PrintableSlot {
        var jointNumber: Int
        var feetRect: CGRect
        var hundredthsRect: CGRect
        var lengthRect: CGRect
        var center: CGPoint { CGPoint(x: lengthRect.midX, y: lengthRect.midY) }
    }

    private struct PrintedPairingResult {
        var pairs: [Pair]
        var firstJointNumber: Int
        var minimumLastJointNumber: Int
        var reviewJointNumbers: Set<Int>
        var startJoint: TallyStartJointDraft
    }

    private struct PairSelection {
        var pairs: [Pair]
        var firstJointNumber: Int
        var minimumLastJointNumber: Int
        var reviewJointNumbers: Set<Int>
        var startJoint: TallyStartJointDraft
    }

    static func parse(tokens: [RecognizedToken]) -> TallyParseResult {
        let numericTokens = tokens.map { token in
            let normalizedDigits = normalizedOCRDigits(in: token.text)
            return NumericToken(
                token: token,
                integerValue: Int(normalizedDigits),
                lengthHundredths: parseHundredths(fromRecognizedText: token.text),
                normalizedDigitCount: normalizedDigits.count
            )
        }

        let lengthTokens = makeLengthTokens(from: numericTokens)

        let jointTokens = numericTokens.filter { token in
            guard let joint = token.integerValue else { return false }
            return (1...999).contains(joint)
        }

        let medianHeight = median(lengthTokens.map(\.height))
        let yTolerance = max(CGFloat(0.016), medianHeight * 1.35)
        let maxXDistance = CGFloat(0.34)

        var usedLengthIDs = Set<UUID>()
        var pairs: [Pair] = []

        let sortedJointTokens = jointTokens.sorted {
            if abs($0.midY - $1.midY) > yTolerance {
                return $0.midY > $1.midY
            }
            return $0.midX < $1.midX
        }

        for jointToken in sortedJointTokens {
            guard let jointNumber = jointToken.integerValue else { continue }

            let candidateLengths = lengthTokens.filter { lengthToken in
                guard !usedLengthIDs.contains(lengthToken.token.id) else { return false }
                let yMatches = abs(lengthToken.midY - jointToken.midY) <= yTolerance
                let xDistance = lengthToken.midX - jointToken.midX
                return yMatches && xDistance >= -0.005 && xDistance <= maxXDistance
            }

            guard let lengthToken = candidateLengths.min(by: {
                abs($0.midX - jointToken.midX) < abs($1.midX - jointToken.midX)
            }), let lengthHundredths = lengthToken.lengthHundredths else {
                continue
            }

            usedLengthIDs.insert(lengthToken.token.id)
            pairs.append(Pair(
                jointNumber: jointNumber,
                lengthHundredths: lengthHundredths,
                rawLengthText: lengthToken.token.text,
                confidence: min(jointToken.token.confidence, lengthToken.token.confidence),
                x: jointToken.midX,
                y: jointToken.midY,
                lengthID: lengthToken.token.id,
                inferredFromGrid: false
            ))
        }

        let gridResult = inferGridPairs(
            from: lengthTokens,
            directPairs: pairs,
            yTolerance: yTolerance
        )
        let nonGridPairs = pairs.filter { !gridResult.replacedLengthIDs.contains($0.lengthID) }
        let gridPairs = applyPrintedPageOffsetIfNeeded(to: deduplicate(nonGridPairs + gridResult.pairs))
        let printedResult = inferPrintedSheetPairs(
            from: numericTokens,
            lengthTokens: lengthTokens
        )
        let sequentialPairs = inferSequentialPairs(from: lengthTokens, yTolerance: yTolerance)
        let selection = bestPairs(
            printedResult: printedResult,
            gridPairs: gridPairs,
            sequentialPairs: sequentialPairs
        )
        let rows = buildRows(
            from: selection.pairs,
            firstJointNumber: selection.firstJointNumber,
            minimumLastJointNumber: selection.minimumLastJointNumber,
            reviewJointNumbers: selection.reviewJointNumbers
        )
        let warnings = buildWarnings(
            tokens: tokens,
            pairs: selection.pairs,
            firstJointNumber: selection.firstJointNumber,
            reviewJointNumbers: selection.reviewJointNumbers,
            startJoint: selection.startJoint
        )

        return TallyParseResult(
            rows: rows,
            startJoint: selection.startJoint,
            recognizedTokenCount: tokens.count,
            pairedRowCount: selection.pairs.count,
            warnings: warnings
        )
    }

    private static func makeLengthTokens(from numericTokens: [NumericToken]) -> [NumericToken] {
        let fullLengthTokens = numericTokens.filter { token in
            guard let length = token.lengthHundredths else { return false }
            if length < 2_400, token.midY > 0.82 {
                return false
            }
            return (1_800...5_000).contains(length)
        }

        let splitLengthTokens = inferSplitLengthTokens(from: numericTokens)
        return deduplicateLengthTokens(fullLengthTokens + splitLengthTokens)
    }

    private static func inferSplitLengthTokens(from numericTokens: [NumericToken]) -> [NumericToken] {
        let heights = numericTokens.map(\.height)
        let yTolerance = max(CGFloat(0.012), median(heights) * 1.25)

        let feetTokens = numericTokens.filter { token in
            guard let value = token.integerValue else { return false }
            return (20...49).contains(value) && token.digitCount <= 2
        }

        let fractionTokens = numericTokens.filter { token in
            guard let value = token.integerValue else { return false }
            return (0...99).contains(value) && token.digitCount == 2
        }

        return feetTokens.compactMap { feetToken in
            guard let feet = feetToken.integerValue else { return nil }

            let candidates = fractionTokens.filter { fractionToken in
                fractionToken.token.id != feetToken.token.id
                    && abs(fractionToken.midY - feetToken.midY) <= yTolerance
                    && (fractionToken.midX - feetToken.midX) >= 0.012
                    && (fractionToken.midX - feetToken.midX) <= 0.095
            }

            guard let fractionToken = candidates.min(by: {
                abs($0.midX - feetToken.midX) < abs($1.midX - feetToken.midX)
            }), let fraction = fractionToken.integerValue else {
                return nil
            }

            let hundredths = feet * 100 + fraction
            guard (1_800...5_000).contains(hundredths) else { return nil }

            let boundingBox = feetToken.token.boundingBox.union(fractionToken.token.boundingBox)
            let rawText = "\(feetToken.token.text)|\(fractionToken.token.text)"
            let token = RecognizedToken(
                text: rawText,
                boundingBox: boundingBox,
                confidence: min(feetToken.token.confidence, fractionToken.token.confidence) * 0.9
            )

            return NumericToken(
                token: token,
                integerValue: hundredths,
                lengthHundredths: hundredths,
                normalizedDigitCount: String(hundredths).count
            )
        }
    }

    private static func deduplicateLengthTokens(_ tokens: [NumericToken]) -> [NumericToken] {
        var deduplicated: [NumericToken] = []

        for token in tokens.sorted(by: { $0.token.confidence > $1.token.confidence }) {
            let isDuplicate = deduplicated.contains { existing in
                abs(existing.midX - token.midX) < 0.015
                    && abs(existing.midY - token.midY) < 0.012
            }

            if !isDuplicate {
                deduplicated.append(token)
            }
        }

        return deduplicated
    }

    private static func bestPairs(
        printedResult: PrintedPairingResult,
        gridPairs: [Pair],
        sequentialPairs: [Pair]
    ) -> PairSelection {
        if printedResult.pairs.count >= 5 {
            return PairSelection(
                pairs: printedResult.pairs,
                firstJointNumber: printedResult.firstJointNumber,
                minimumLastJointNumber: printedResult.minimumLastJointNumber,
                reviewJointNumbers: printedResult.reviewJointNumbers,
                startJoint: printedResult.startJoint
            )
        }

        guard sequentialPairs.count >= 5 else {
            return PairSelection(
                pairs: gridPairs,
                firstJointNumber: 1,
                minimumLastJointNumber: 0,
                reviewJointNumbers: [],
                startJoint: inferredStartJoint(from: gridPairs)
            )
        }
        guard gridPairs.count >= 5 else {
            return PairSelection(
                pairs: sequentialPairs,
                firstJointNumber: 1,
                minimumLastJointNumber: 0,
                reviewJointNumbers: [],
                startJoint: inferredStartJoint(from: sequentialPairs)
            )
        }

        let pairs = sequentialPairs.count >= gridPairs.count ? sequentialPairs : gridPairs
        return PairSelection(
            pairs: pairs,
            firstJointNumber: 1,
            minimumLastJointNumber: 0,
            reviewJointNumbers: [],
            startJoint: inferredStartJoint(from: pairs)
        )
    }

    private static func inferPrintedSheetPairs(
        from numericTokens: [NumericToken],
        lengthTokens: [NumericToken]
    ) -> PrintedPairingResult {
        let slots = printableSheetSlots()
        let startJoint = inferPrintablePageStartJoint(from: numericTokens)
        let pageStartJoint = Int(startJoint.text) ?? 1
        var pairs: [Pair] = []
        var highestDetectedLocalJoint = 0
        var reviewJointNumbers = Set<Int>()

        for slot in slots {
            let outputJointNumber = pageStartJoint + slot.jointNumber - 1
            let hasEntryEvidence = numericTokens.contains { token in
                let point = CGPoint(x: token.midX, y: token.midY)
                return token.integerValue != nil
                    && token.digitCount <= 2
                    && (slot.feetRect.contains(point) || slot.hundredthsRect.contains(point))
            }

            if hasEntryEvidence {
                highestDetectedLocalJoint = max(highestDetectedLocalJoint, slot.jointNumber)
            }

            if let lengthToken = bestToken(in: slot.lengthRect, from: lengthTokens, center: slot.center),
               let lengthHundredths = lengthToken.lengthHundredths,
               isNormalJointLength(lengthHundredths) {
                highestDetectedLocalJoint = max(highestDetectedLocalJoint, slot.jointNumber)
                pairs.append(Pair(
                    jointNumber: outputJointNumber,
                    lengthHundredths: lengthHundredths,
                    rawLengthText: lengthToken.token.text,
                    confidence: lengthToken.token.confidence,
                    x: lengthToken.midX,
                    y: lengthToken.midY,
                    lengthID: lengthToken.token.id,
                    inferredFromGrid: false
                ))
                continue
            }

            guard let feetToken = bestFeetToken(in: slot.feetRect, from: numericTokens),
                  let hundredthsToken = bestHundredthsToken(in: slot.hundredthsRect, from: numericTokens),
                  let feet = feetToken.integerValue,
                  let hundredths = hundredthsToken.integerValue else {
                if hasEntryEvidence {
                    reviewJointNumbers.insert(outputJointNumber)
                }
                continue
            }

            let lengthHundredths = feet * 100 + hundredths
            guard isNormalJointLength(lengthHundredths) else {
                highestDetectedLocalJoint = max(highestDetectedLocalJoint, slot.jointNumber)
                reviewJointNumbers.insert(outputJointNumber)
                continue
            }

            highestDetectedLocalJoint = max(highestDetectedLocalJoint, slot.jointNumber)
            pairs.append(Pair(
                jointNumber: outputJointNumber,
                lengthHundredths: lengthHundredths,
                rawLengthText: "\(feetToken.token.text)|\(hundredthsToken.token.text)",
                confidence: min(feetToken.token.confidence, hundredthsToken.token.confidence) * 0.92,
                x: feetToken.midX,
                y: feetToken.midY,
                lengthID: feetToken.token.id,
                inferredFromGrid: false
            ))
        }

        let minimumLastJointNumber: Int
        if highestDetectedLocalJoint > 0 {
            let roundedLocalJoint = min(roundUpToNextTen(highestDetectedLocalJoint), 100)
            minimumLastJointNumber = pageStartJoint + roundedLocalJoint - 1
            let pairedJointNumbers = Set(pairs.map(\.jointNumber))

            for jointNumber in pageStartJoint...minimumLastJointNumber where !pairedJointNumbers.contains(jointNumber) {
                reviewJointNumbers.insert(jointNumber)
            }
        } else {
            minimumLastJointNumber = 0
        }

        return PrintedPairingResult(
            pairs: pairs,
            firstJointNumber: pageStartJoint,
            minimumLastJointNumber: minimumLastJointNumber,
            reviewJointNumbers: reviewJointNumbers,
            startJoint: startJoint
        )
    }

    private static func inferredStartJoint(from pairs: [Pair]) -> TallyStartJointDraft {
        let firstJoint = pairs
            .map(\.jointNumber)
            .filter { $0 > 0 }
            .min() ?? 1

        return TallyStartJointDraft(
            text: "\(firstJoint)",
            rawText: "",
            confidence: nil,
            warnings: []
        )
    }

    private static func printableSheetSlots() -> [PrintableSlot] {
        let columnStride = PrintableSheetGeometry.columnWidth + PrintableSheetGeometry.columnGap
        var slots: [PrintableSlot] = []

        for column in 0..<5 {
            let columnX = PrintableSheetGeometry.marginX + CGFloat(column) * columnStride
            let feetX = columnX + PrintableSheetGeometry.jointWidth
            let hundredthsX = feetX + PrintableSheetGeometry.feetWidth

            for row in 0..<20 {
                let block = row / 10
                let rowInBlock = row % 10
                let rowTop = PrintableSheetGeometry.rowTopY
                    - CGFloat(block) * (PrintableSheetGeometry.rowHeight * 10 + PrintableSheetGeometry.blockGap)
                    - CGFloat(rowInBlock) * PrintableSheetGeometry.rowHeight
                let rowBottom = rowTop - PrintableSheetGeometry.rowHeight
                let rowY = rowBottom + 2
                let rowHeight = PrintableSheetGeometry.rowHeight - 4
                let feetRect = PrintableSheetGeometry.normalizedRect(fromPDFRect: CGRect(
                    x: feetX + 6,
                    y: rowY,
                    width: PrintableSheetGeometry.feetWidth - 9,
                    height: rowHeight
                ))
                let hundredthsRect = PrintableSheetGeometry.normalizedRect(fromPDFRect: CGRect(
                    x: hundredthsX + 5,
                    y: rowY,
                    width: PrintableSheetGeometry.hundredthsWidth - 9,
                    height: rowHeight
                ))

                slots.append(PrintableSlot(
                    jointNumber: column * 20 + row + 1,
                    feetRect: feetRect,
                    hundredthsRect: hundredthsRect,
                    lengthRect: feetRect.union(hundredthsRect).insetBy(dx: -0.003, dy: -0.004)
                ))
            }
        }

        return slots
    }

    private static func bestFeetToken(in rect: CGRect, from tokens: [NumericToken]) -> NumericToken? {
        let candidates = tokens.filter { token in
            guard let value = token.integerValue else { return false }
            return rect.contains(CGPoint(x: token.midX, y: token.midY))
                && (28...34).contains(value)
                && token.digitCount == 2
        }

        return bestToken(in: rect, from: candidates, center: CGPoint(x: rect.midX, y: rect.midY))
    }

    private static func bestHundredthsToken(in rect: CGRect, from tokens: [NumericToken]) -> NumericToken? {
        let candidates = tokens.filter { token in
            guard let value = token.integerValue else { return false }
            return rect.contains(CGPoint(x: token.midX, y: token.midY))
                && (0...99).contains(value)
                && token.digitCount == 2
        }

        return bestToken(in: rect, from: candidates, center: CGPoint(x: rect.midX, y: rect.midY))
    }

    private static func isNormalJointLength(_ hundredths: Int) -> Bool {
        (2_800...3_400).contains(hundredths)
    }

    private static func inferPrintablePageStartJoint(from tokens: [NumericToken]) -> TallyStartJointDraft {
        let candidates = tokens.filter { token in
            guard let value = token.integerValue else { return false }
            return PrintableSheetGeometry.startJointRect.contains(CGPoint(x: token.midX, y: token.midY))
                && ((1...90).contains(value) || (101...901).contains(value))
        }

        let normalizedCandidates = candidates.compactMap { token -> (token: NumericToken, startJoint: Int)? in
            guard let startJoint = normalizedPageStartJoint(from: token.integerValue) else { return nil }
            return (token, startJoint)
        }

        guard let candidate = bestStartJointCandidate(normalizedCandidates) else {
            return TallyStartJointDraft(
                text: "1",
                rawText: "",
                confidence: nil,
                warnings: ["Review"]
            )
        }

        var warnings: [String] = []
        if candidate.token.token.confidence < 0.65 {
            warnings.append("Review")
        }

        let distinctStartJoints = Set(normalizedCandidates.map { $0.startJoint })
        if distinctStartJoints.count > 1 {
            warnings.append("Review")
        }

        return TallyStartJointDraft(
            text: "\(candidate.startJoint)",
            rawText: candidate.token.token.text,
            confidence: candidate.token.token.confidence,
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private static func bestStartJointCandidate(
        _ candidates: [(token: NumericToken, startJoint: Int)]
    ) -> (token: NumericToken, startJoint: Int)? {
        let preferredCandidates = candidates.contains { $0.startJoint > 1 }
            ? candidates.filter { $0.startJoint > 1 }
            : candidates

        let center = CGPoint(
            x: PrintableSheetGeometry.startJointRect.midX,
            y: PrintableSheetGeometry.startJointRect.midY
        )

        return preferredCandidates.min {
            tokenScore($0.token, target: center) < tokenScore($1.token, target: center)
        }
    }

    private static func normalizedPageStartJoint(from value: Int?) -> Int? {
        guard let value else { return nil }

        if value == 1 {
            return 1
        }

        if value >= 101, value <= 901, value % 100 == 1 {
            return value
        }

        if value >= 10, value <= 90, value.isMultiple(of: 10) {
            return value * 10 + 1
        }

        return nil
    }

    private static func bestToken(
        in rect: CGRect,
        from tokens: [NumericToken],
        center: CGPoint
    ) -> NumericToken? {
        let candidates = tokens.filter { token in
            rect.contains(CGPoint(x: token.midX, y: token.midY))
        }

        return candidates.min { lhs, rhs in
            tokenScore(lhs, target: center) < tokenScore(rhs, target: center)
        }
    }

    private static func tokenScore(_ token: NumericToken, target: CGPoint) -> CGFloat {
        let dx = token.midX - target.x
        let dy = token.midY - target.y
        let distance = sqrt(dx * dx + dy * dy)
        let confidencePenalty = CGFloat(1 - min(max(token.token.confidence, 0), 1)) * 0.025
        return distance + confidencePenalty
    }

    private static func deduplicate(_ pairs: [Pair]) -> [Pair] {
        var bestByJoint: [Int: Pair] = [:]

        for pair in pairs {
            if let existing = bestByJoint[pair.jointNumber] {
                if pair.confidence > existing.confidence {
                    bestByJoint[pair.jointNumber] = pair
                }
            } else {
                bestByJoint[pair.jointNumber] = pair
            }
        }

        return bestByJoint.values.sorted { $0.jointNumber < $1.jointNumber }
    }

    private static func inferSequentialPairs(
        from lengthTokens: [NumericToken],
        yTolerance: CGFloat
    ) -> [Pair] {
        let xClusters = clusterByX(lengthTokens)
            .filter { $0.count >= 2 }
            .sorted { ($0.map(\.midX).average ?? 0) < ($1.map(\.midX).average ?? 0) }

        let orderedTokens = xClusters.flatMap { xCluster in
            splitIntoVerticalBlocks(xCluster, yTolerance: yTolerance)
                .flatMap { block in
                    block.sorted { $0.midY > $1.midY }
                }
        }

        return orderedTokens.enumerated().compactMap { index, token in
            guard let lengthHundredths = token.lengthHundredths else { return nil }
            return Pair(
                jointNumber: index + 1,
                lengthHundredths: lengthHundredths,
                rawLengthText: token.token.text,
                confidence: token.token.confidence * 0.9,
                x: token.midX,
                y: token.midY,
                lengthID: token.token.id,
                inferredFromGrid: true
            )
        }
    }

    private static func inferGridPairs(
        from lengthTokens: [NumericToken],
        directPairs: [Pair],
        yTolerance: CGFloat
    ) -> (pairs: [Pair], replacedLengthIDs: Set<UUID>) {
        let pairByLengthID = Dictionary(grouping: directPairs, by: \.lengthID)
        var inferredPairs: [Pair] = []
        var replacedLengthIDs = Set<UUID>()

        let xClusters = clusterByX(lengthTokens).filter { $0.count >= 8 }

        for (xIndex, xCluster) in xClusters.enumerated() {
            for (blockIndex, block) in splitIntoVerticalBlocks(xCluster, yTolerance: yTolerance).enumerated() {
                let sortedBlock = block.sorted { $0.midY > $1.midY }
                guard sortedBlock.count >= 5 else { continue }

                var offsets: [Int] = []
                var manualStartOffset: Int?

                for (index, token) in sortedBlock.enumerated() {
                    guard let pair = pairByLengthID[token.token.id]?.first else { continue }
                    let offset = pair.jointNumber - index
                    offsets.append(offset)

                    if index == 0, pair.jointNumber > 100, pair.jointNumber % 100 == 1 {
                        manualStartOffset = pair.jointNumber
                    }
                }

                let templateOffset = templateStartOffset(
                    xIndex: xIndex,
                    blockIndex: blockIndex,
                    xClusterCount: xClusters.count
                )

                guard offsets.count >= 3 || templateOffset != nil else { continue }
                let offset = manualStartOffset ?? templateOffset ?? (offsets.count >= 3 ? medianInt(offsets) : 1)

                for (index, token) in sortedBlock.enumerated() {
                    guard let lengthHundredths = token.lengthHundredths else { continue }
                    let inferredJoint = offset + index
                    guard inferredJoint > 0 else { continue }

                    replacedLengthIDs.insert(token.token.id)
                    let directPair = pairByLengthID[token.token.id]?.first
                    inferredPairs.append(Pair(
                        jointNumber: inferredJoint,
                        lengthHundredths: lengthHundredths,
                        rawLengthText: token.token.text,
                        confidence: (directPair?.confidence ?? token.token.confidence) * 0.85,
                        x: token.midX,
                        y: token.midY,
                        lengthID: token.token.id,
                        inferredFromGrid: directPair?.jointNumber != inferredJoint
                    ))
                }
            }
        }

        return (inferredPairs, replacedLengthIDs)
    }

    private static func templateStartOffset(
        xIndex: Int,
        blockIndex: Int,
        xClusterCount: Int
    ) -> Int? {
        if xClusterCount >= 5, blockIndex < 5 {
            return xIndex * 50 + blockIndex * 10 + 1
        }

        guard xClusterCount >= 4 else { return nil }

        let topStarts = [1, 21, 41, 71]
        let middleStarts = [11, 31, 51, 81]
        let bottomStarts = [nil, nil, 61, 91] as [Int?]

        guard xIndex < topStarts.count else { return nil }

        switch blockIndex {
        case 0:
            return topStarts[xIndex]
        case 1:
            return middleStarts[xIndex]
        case 2:
            return bottomStarts[xIndex] ?? nil
        default:
            return nil
        }
    }

    private static func clusterByX(_ tokens: [NumericToken]) -> [[NumericToken]] {
        let sorted = tokens.sorted { $0.midX < $1.midX }
        var clusters: [[NumericToken]] = []

        for token in sorted {
            if var last = clusters.last,
               let clusterMidX = last.map(\.midX).average,
               abs(token.midX - clusterMidX) <= 0.055 {
                last.append(token)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([token])
            }
        }

        return clusters
    }

    private static func splitIntoVerticalBlocks(_ tokens: [NumericToken], yTolerance: CGFloat) -> [[NumericToken]] {
        let sorted = tokens.sorted { $0.midY > $1.midY }
        var blocks: [[NumericToken]] = []
        let gapThreshold = max(CGFloat(0.040), yTolerance * 2.5)

        for token in sorted {
            if var last = blocks.last,
               let previous = last.last,
               abs(previous.midY - token.midY) <= gapThreshold {
                last.append(token)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([token])
            }
        }

        return blocks
    }

    private static func applyPrintedPageOffsetIfNeeded(to pairs: [Pair]) -> [Pair] {
        let printedCount = pairs.filter { (1...100).contains($0.jointNumber) }.count
        guard printedCount >= 10 else { return pairs }

        guard let startPair = pairs
            .filter({ $0.jointNumber > 100 && $0.jointNumber % 100 == 1 })
            .min(by: { $0.jointNumber < $1.jointNumber }) else {
            return pairs
        }

        let startJoint = startPair.jointNumber

        return pairs.map { pair in
            if (1...100).contains(pair.jointNumber) {
                var adjusted = pair
                adjusted.jointNumber = startJoint + pair.jointNumber - 1
                return adjusted
            }
            return pair
        }
    }

    private static func buildRows(
        from pairs: [Pair],
        firstJointNumber: Int,
        minimumLastJointNumber: Int,
        reviewJointNumbers: Set<Int>
    ) -> [TallyRowDraft] {
        let maxPairJoint = pairs.map(\.jointNumber).max() ?? 0
        let minReviewJoint = reviewJointNumbers.min()
        let maxReviewJoint = reviewJointNumbers.max() ?? 0
        let firstJoint = min(firstJointNumber, pairs.map(\.jointNumber).min() ?? firstJointNumber, minReviewJoint ?? firstJointNumber)
        let maxJoint = max(maxPairJoint, maxReviewJoint, minimumLastJointNumber)

        guard maxJoint >= firstJoint, maxJoint <= 999 else {
            return pairs
                .sorted { $0.jointNumber < $1.jointNumber }
                .map(rowDraft)
        }

        let pairByJoint = Dictionary(uniqueKeysWithValues: pairs.map { ($0.jointNumber, $0) })

        return (firstJoint...maxJoint).map { joint in
            if let pair = pairByJoint[joint] {
                return rowDraft(from: pair)
            }

            return TallyRowDraft(
                jointText: "\(joint)",
                lengthText: "",
                rawLengthText: "",
                confidence: nil,
                warnings: reviewJointNumbers.contains(joint) ? ["Review"] : ["Blank"]
            )
        }
    }

    private static func rowDraft(from pair: Pair) -> TallyRowDraft {
        var warnings: [String] = []

        if pair.confidence < 0.55 {
            warnings.append("Review")
        }

        if pair.inferredFromGrid {
            warnings.append("Infer")
        }

        if !(2_800...3_400).contains(pair.lengthHundredths) {
            warnings.append("Range")
        }

        return TallyRowDraft(
            jointText: "\(pair.jointNumber)",
            lengthText: TallyLengthFormatter.displayLength(fromHundredths: pair.lengthHundredths),
            rawLengthText: pair.rawLengthText,
            confidence: pair.confidence,
            warnings: warnings
        )
    }

    private static func buildWarnings(
        tokens: [RecognizedToken],
        pairs: [Pair],
        firstJointNumber: Int,
        reviewJointNumbers: Set<Int>,
        startJoint: TallyStartJointDraft
    ) -> [String] {
        var warnings: [String] = []

        if pairs.isEmpty {
            warnings.append("No joint/length pairs found. Try a flatter, brighter photo.")
        }

        let lowConfidenceCount = pairs.filter { $0.confidence < 0.55 }.count
        if lowConfidenceCount > 0 {
            warnings.append("\(lowConfidenceCount) rows need review for low OCR confidence.")
        }

        let rangeCount = pairs.filter { !(2_800...3_400).contains($0.lengthHundredths) }.count
        if rangeCount > 0 {
            warnings.append("\(rangeCount) rows are outside the normal 28.00'-34.00' joint range.")
        }

        if !reviewJointNumbers.isEmpty {
            warnings.append("Skipped \(reviewJointNumbers.count) uncertain rows for manual entry.")
        }

        if startJoint.needsReview {
            warnings.append("Review the starting joint for this sheet.")
        }

        if firstJointNumber > 1 {
            warnings.append("Detected page start Jt \(firstJointNumber).")
        }

        warnings.append("Recognized \(tokens.count) numeric tokens and paired \(pairs.count) rows.")
        return warnings
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0.012 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func medianInt(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func roundUpToNextTen(_ value: Int) -> Int {
        ((value + 9) / 10) * 10
    }

    private static func normalizedOCRDigits(in text: String) -> String {
        var digits = ""

        for character in text {
            if character.isNumber {
                digits.append(character)
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

        return digits
    }

    private static func parseHundredths(fromRecognizedText text: String) -> Int? {
        let trimmed = text
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "ft", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains(".") {
            let normalizedDecimal = trimmed.map { character -> Character in
                switch character {
                case "O", "o":
                    return "0"
                case "I", "l", "|":
                    return "1"
                case "S", "s":
                    return "5"
                default:
                    return character
                }
            }

            guard let value = Double(String(normalizedDecimal)), value > 0 else { return nil }
            return Int((value * 100).rounded())
        }

        let digits = normalizedOCRDigits(in: trimmed)
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

private extension Array where Element == CGFloat {
    var average: CGFloat? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / CGFloat(count)
    }
}

private enum PrintableSheetGeometry {
    static let pageWidth = CGFloat(792)
    static let pageHeight = CGFloat(612)
    static let pageRect = CGRect(x: 0.015, y: 0.015, width: 0.97, height: 0.97)
    static let marginX = CGFloat(25.2)
    static let columnWidth = CGFloat(141.408)
    static let columnGap = CGFloat(8.64)
    static let jointWidth = CGFloat(28.8)
    static let feetWidth = CGFloat(41.76)
    static let hundredthsWidth = CGFloat(47.52)
    static let rowTopY = CGFloat(521.28)
    static let rowHeight = CGFloat(25.866)
    static let blockGap = CGFloat(5.4)
    static let startJointRect = normalizedRect(fromPDFRect: CGRect(x: 595, y: 545, width: 160, height: 38))

    static func normalizedRect(fromPDFRect pdfRect: CGRect) -> CGRect {
        let clamped = pdfRect.intersection(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        return CGRect(
            x: pageRect.minX + clamped.minX / pageWidth * pageRect.width,
            y: pageRect.minY + clamped.minY / pageHeight * pageRect.height,
            width: clamped.width / pageWidth * pageRect.width,
            height: clamped.height / pageHeight * pageRect.height
        )
    }
}
