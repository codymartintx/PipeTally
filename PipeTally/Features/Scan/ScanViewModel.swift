import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

enum ScanState: Equatable {
    case idle
    case processing(String)
    case finished
    case failed(String)
}

struct SelectedTallyImage: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage
    var title: String
    var rows: [TallyRowDraft] = []
    var summary: [String] = []
    var startJointText = "1"
    var startJointRawText = ""
    var startJointConfidence: Float?
    var startJointNeedsReview = false
    var recognizedTokenCount = 0
    var pairedRowCount = 0
    var scanState: ScanState = .idle

    var populatedRows: [TallyRowDraft] {
        rows.filter { !$0.isBlank }
    }

    var rowReviewCount: Int {
        rows.filter { $0.warnings.contains("Review") }.count
    }

    var reviewCount: Int {
        rowReviewCount + (startJointNeedsReview ? 1 : 0)
    }

    var startJointConfidenceText: String {
        guard let startJointConfidence else { return "" }
        return "\(Int((startJointConfidence * 100).rounded()))%"
    }

    var jointRangeText: String {
        let jointNumbers = rows.compactMap { Int($0.jointText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let first = jointNumbers.min(), let last = jointNumbers.max() else {
            return "No joints"
        }
        return first == last ? "Jt \(first)" : "Jts \(first)-\(last)"
    }
}

@MainActor
@Observable
final class ScanViewModel {
    var scanState: ScanState = .idle
    var selectedImages: [SelectedTallyImage] = []
    var activeImageID: SelectedTallyImage.ID?

    var activeSheetIndex: Int? {
        guard let activeImageID else { return nil }
        return selectedImages.firstIndex { $0.id == activeImageID }
    }

    var activeImage: SelectedTallyImage? {
        guard let activeSheetIndex else { return nil }
        return selectedImages[activeSheetIndex]
    }

    var activePreviewImage: UIImage? {
        activeImage?.image
    }

    var allRows: [TallyRowDraft] {
        selectedImages.flatMap(\.rows)
    }

    var hasExportableRows: Bool {
        allRows.contains { row in
            Int(row.jointText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }

    var hasContent: Bool {
        !selectedImages.isEmpty || hasExportableRows
    }

    func scanSample(named resourceName: String, extension fileExtension: String = "png", title: String) async {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension),
              let image = UIImage(contentsOfFile: url.path) else {
            scanState = .failed("Sample image is missing from the app bundle.")
            return
        }

        let sheet = SelectedTallyImage(image: image, title: title)
        selectedImages = [sheet]
        activeImageID = sheet.id
        await scanSheet(sheet.id)
    }

    func scanPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await loadPickedPhotos([item])
    }

    func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        scanState = .processing("Loading images")

        var newImageIDs: [SelectedTallyImage.ID] = []
        var loadError: String?

        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    loadError = "Could not load one of the selected images."
                    continue
                }

                let selectedImage = SelectedTallyImage(
                    image: image,
                    title: "Sheet \(selectedImages.count + 1)"
                )
                selectedImages.append(selectedImage)
                newImageIDs.append(selectedImage.id)
            } catch {
                loadError = error.localizedDescription
            }
        }

        retitleSelectedImages()

        guard !newImageIDs.isEmpty else {
            scanState = .failed(loadError ?? "Could not load the selected images.")
            return
        }

        activeImageID = newImageIDs.first

        for id in newImageIDs {
            await scanSheet(id)
        }

        if let failedSheet = selectedImages.first(where: {
            if case .failed = $0.scanState { return true }
            return false
        }) {
            scanState = .failed("\(failedSheet.title) could not be read.")
        } else if let loadError {
            scanState = .failed(loadError)
        } else {
            scanState = .finished
        }
    }

    func selectImage(_ id: SelectedTallyImage.ID) {
        guard selectedImages.contains(where: { $0.id == id }) else { return }
        activeImageID = id
    }

    func removeImage(_ id: SelectedTallyImage.ID) {
        guard let removedIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeImageID == id
        selectedImages.remove(at: removedIndex)
        retitleSelectedImages()

        if selectedImages.isEmpty {
            clear()
            return
        }

        guard wasActive else { return }

        let nextIndex = min(removedIndex, selectedImages.count - 1)
        activeImageID = selectedImages[nextIndex].id
    }

    func moveImage(_ id: SelectedTallyImage.ID, by offset: Int) {
        guard let currentIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = currentIndex + offset
        guard selectedImages.indices.contains(newIndex) else { return }
        selectedImages.swapAt(currentIndex, newIndex)
        retitleSelectedImages()
    }

    func canMoveImage(_ id: SelectedTallyImage.ID, by offset: Int) -> Bool {
        guard let currentIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return false }
        return selectedImages.indices.contains(currentIndex + offset)
    }

    func applyStartJoint(forSheetID id: SelectedTallyImage.ID) {
        guard let sheetIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return }
        let trimmedStart = selectedImages[sheetIndex].startJointText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let startJoint = Int(trimmedStart), startJoint > 0 else {
            selectedImages[sheetIndex].startJointNeedsReview = true
            appendSummary("Review the starting joint for this sheet.", toSheetAt: sheetIndex)
            return
        }

        selectedImages[sheetIndex].startJointText = "\(startJoint)"
        selectedImages[sheetIndex].startJointNeedsReview = false
        selectedImages[sheetIndex].summary.removeAll { $0 == "Review the starting joint for this sheet." }

        for rowIndex in selectedImages[sheetIndex].rows.indices {
            selectedImages[sheetIndex].rows[rowIndex].jointText = "\(startJoint + rowIndex)"
        }
    }

    func exportExcelFile() throws -> URL {
        try TallyExcelExporter.export(rows: allRows)
    }

    func clear() {
        selectedImages = []
        activeImageID = nil
        scanState = .idle
    }

    private func scanSheet(_ id: SelectedTallyImage.ID) async {
        guard let initialIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return }
        let image = selectedImages[initialIndex].image
        let title = selectedImages[initialIndex].title

        setScanState(.processing("Reading image"), forSheetID: id)
        scanState = .processing("Reading \(title)")

        do {
            let tokens = try await TallyOCRService.recognizeTokens(in: image)
            setScanState(.processing("Pairing joints"), forSheetID: id)
            scanState = .processing("Pairing \(title)")

            let result = TallyParser.parse(tokens: tokens)
            guard let sheetIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return }

            selectedImages[sheetIndex].rows = result.rows
            selectedImages[sheetIndex].summary = result.warnings
            selectedImages[sheetIndex].startJointText = result.startJoint.text
            selectedImages[sheetIndex].startJointRawText = result.startJoint.rawText
            selectedImages[sheetIndex].startJointConfidence = result.startJoint.confidence
            selectedImages[sheetIndex].startJointNeedsReview = result.startJoint.needsReview
            selectedImages[sheetIndex].recognizedTokenCount = result.recognizedTokenCount
            selectedImages[sheetIndex].pairedRowCount = result.pairedRowCount
            selectedImages[sheetIndex].scanState = .finished
        } catch {
            setScanState(.failed(error.localizedDescription), forSheetID: id)
            scanState = .failed(error.localizedDescription)
        }
    }

    private func setScanState(_ state: ScanState, forSheetID id: SelectedTallyImage.ID) {
        guard let sheetIndex = selectedImages.firstIndex(where: { $0.id == id }) else { return }
        selectedImages[sheetIndex].scanState = state
    }

    private func appendSummary(_ message: String, toSheetAt sheetIndex: Int) {
        guard !selectedImages[sheetIndex].summary.contains(message) else { return }
        selectedImages[sheetIndex].summary.append(message)
    }

    private func retitleSelectedImages() {
        for index in selectedImages.indices {
            selectedImages[index].title = "Sheet \(index + 1)"
        }
    }
}
