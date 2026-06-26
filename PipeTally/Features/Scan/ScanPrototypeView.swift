import PhotosUI
import SwiftUI
import UIKit

struct ScanPrototypeView: View {
    @State private var model = ScanViewModel()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageViewerItem: ImageViewerItem?
    @State private var shareSheetItem: ShareSheetItem?

    var body: some View {
        NavigationStack {
            List {
                scanControlsSection

                if !model.selectedImages.isEmpty {
                    imageTraySection
                }

                if let activeImage = model.activeImage {
                    previewSection(activeImage)
                }

                if !model.selectedImages.isEmpty {
                    sheetReviewSections
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pipe Tally")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        shareExcel()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!model.hasExportableRows)
                    .accessibilityLabel("Share Excel")

                    Button("Clear") {
                        model.clear()
                        selectedPhotos = []
                    }
                    .disabled(!model.hasContent)
                }
            }
            .overlay {
                if case let .processing(message) = model.scanState {
                    ProcessingOverlay(message: message)
                }
            }
            .onChange(of: selectedPhotos) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task {
                    await model.loadPickedPhotos(newValue)
                    selectedPhotos = []
                }
            }
            .fullScreenCover(item: $imageViewerItem) { item in
                ImageReviewView(image: item.image)
            }
            .sheet(item: $shareSheetItem) { item in
                ActivityView(activityItems: [item.url])
            }
        }
    }

    private func shareExcel() {
        do {
            shareSheetItem = ShareSheetItem(url: try model.exportExcelFile())
        } catch {
            model.scanState = .failed(error.localizedDescription)
        }
    }

    private var scanControlsSection: some View {
        Section {
            let hasNoImages = model.selectedImages.isEmpty
            let labelText = hasNoImages ? "Choose tally images" : "Add tally images"

            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 12, matching: .images) {
                Label(
                    labelText,
                    systemImage: "photo.on.rectangle.angled"
                )
            }

            if case let .failed(message) = model.scanState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Scan")
        } footer: {
            Text("Pick photos saved on this phone. New picks are added to the current job; tap a thumbnail to preview that sheet or use the expand icon to proofread it.")
        }
    }

    private var imageTraySection: some View {
        Section("Selected Images") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.selectedImages) { selectedImage in
                        ImageThumbnailCard(
                            selectedImage: selectedImage,
                            isActive: selectedImage.id == model.activeImageID,
                            canMoveLeft: model.canMoveImage(selectedImage.id, by: -1),
                            canMoveRight: model.canMoveImage(selectedImage.id, by: 1),
                            onSelect: {
                                model.selectImage(selectedImage.id)
                            },
                            onZoom: {
                                imageViewerItem = ImageViewerItem(image: selectedImage.image)
                            },
                            onMoveLeft: {
                                model.moveImage(selectedImage.id, by: -1)
                            },
                            onMoveRight: {
                                model.moveImage(selectedImage.id, by: 1)
                            },
                            onRemove: {
                                model.removeImage(selectedImage.id)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func previewSection(_ selectedImage: SelectedTallyImage) -> some View {
        Section("Image") {
            Button {
                imageViewerItem = ImageViewerItem(image: selectedImage.image)
            } label: {
                Image(uiImage: selectedImage.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxHeight: 260)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(selectedImage.title) image")
        }
    }

    @ViewBuilder
    private var sheetReviewSections: some View {
        ForEach(model.selectedImages) { selectedImage in
            if let sheetIndex = model.selectedImages.firstIndex(where: { $0.id == selectedImage.id }) {
                sheetReviewSection(sheetIndex)
            }
        }
    }

    private func sheetReviewSection(_ sheetIndex: Int) -> some View {
        let sheet = model.selectedImages[sheetIndex]

        return Section {
            sheetStatusRow(sheet)
            startJointEditor(sheetIndex: sheetIndex)

            if !sheet.summary.isEmpty {
                ForEach(sheet.summary, id: \.self) { warning in
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if sheet.rows.isEmpty {
                Text(emptyRowsText(for: sheet))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.selectedImages[sheetIndex].rows.indices, id: \.self) { rowIndex in
                    TallyRowEditor(row: $model.selectedImages[sheetIndex].rows[rowIndex])

                    if shouldShowBlockBreak(after: rowIndex, in: model.selectedImages[sheetIndex].rows) {
                        TallyBlockBreak(nextJointText: model.selectedImages[sheetIndex].rows[rowIndex + 1].jointText)
                    }
                }
            }
        } header: {
            HStack {
                Text(sheet.title)
                Spacer()
                Text(sheet.jointRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Change the start joint if OCR missed the large box. Applying renumbers this sheet's rows in order.")
        }
    }

    private func sheetStatusRow(_ sheet: SelectedTallyImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(sheet.populatedRows.count) lengths", systemImage: "list.number")
                Spacer()
                if sheet.reviewCount > 0 {
                    Label("\(sheet.reviewCount) review", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            switch sheet.scanState {
            case .idle:
                EmptyView()
            case let .processing(message):
                Label(message, systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .finished:
                EmptyView()
            case let .failed(message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func startJointEditor(sheetIndex: Int) -> some View {
        let sheet = model.selectedImages[sheetIndex]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Start Joint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Start", text: $model.selectedImages[sheetIndex].startJointText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 104)

                Button("Apply") {
                    model.applyStartJoint(forSheetID: sheet.id)
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if sheet.startJointNeedsReview {
                Label("Review start joint", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if !sheet.startJointRawText.isEmpty || !sheet.startJointConfidenceText.isEmpty {
                Text("Start OCR \(sheet.startJointRawText)  \(sheet.startJointConfidenceText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyRowsText(for sheet: SelectedTallyImage) -> String {
        switch sheet.scanState {
        case .idle:
            return "Waiting to read this sheet."
        case .processing:
            return "Reading this sheet."
        case .finished:
            return "No joints were read for this sheet."
        case .failed:
            return "This sheet could not be read."
        }
    }

    private func shouldShowBlockBreak(after index: Int, in rows: [TallyRowDraft]) -> Bool {
        (index + 1).isMultiple(of: 10) && index < rows.count - 1
    }
}

private struct ImageViewerItem: Identifiable {
    let id = UUID()
    var image: UIImage
}

private struct ShareSheetItem: Identifiable {
    let id = UUID()
    var url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ImageThumbnailCard: View {
    var selectedImage: SelectedTallyImage
    var isActive: Bool
    var canMoveLeft: Bool
    var canMoveRight: Bool
    var onSelect: () -> Void
    var onZoom: () -> Void
    var onMoveLeft: () -> Void
    var onMoveRight: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onZoom) {
                Image(uiImage: selectedImage.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 86, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isActive ? 3 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.bold))
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                            .padding(5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(selectedImage.title)")

            Text(selectedImage.title)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 92)

            HStack(spacing: 4) {
                Button(action: onMoveLeft) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canMoveLeft)

                Button(action: onSelect) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                }
                .foregroundStyle(isActive ? .blue : .secondary)

                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .foregroundStyle(.red)

                Button(action: onMoveRight) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canMoveRight)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .frame(width: 104)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ImageReviewView: View {
    @Environment(\.dismiss) private var dismiss
    var image: UIImage

    var body: some View {
        NavigationStack {
            ZoomableImageView(image: image)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Tally Image")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    var image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        ZoomingImageScrollView(image: image)
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        uiView.setImage(image)
    }
}

private final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    init(image: UIImage) {
        super.init(frame: .zero)
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = true
        bouncesZoom = true

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }

        centerImageIfNeeded()
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        setZoomScale(minimumZoomScale, animated: false)
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }

    private func centerImageIfNeeded() {
        let horizontalInset = max((bounds.width - contentSize.width) / 2, 0)
        let verticalInset = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }
}

private struct TallyRowEditor: View {
    @Binding var row: TallyRowDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Jt", text: $row.jointText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)

                TextField("Length", text: $row.lengthText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 104)

                Spacer()

                if row.isBlank {
                    Text(row.warnings.contains("Review") ? "Review" : "Blank")
                        .font(.caption)
                        .padding(.horizontal, row.warnings.contains("Review") ? 8 : 0)
                        .padding(.vertical, row.warnings.contains("Review") ? 4 : 0)
                        .background(row.warnings.contains("Review") ? .orange.opacity(0.15) : .clear, in: Capsule())
                        .foregroundStyle(row.warnings.contains("Review") ? .orange : .secondary)
                } else if !row.warnings.isEmpty {
                    Text(row.warnings.joined(separator: ", "))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if !row.rawLengthText.isEmpty || !row.confidenceText.isEmpty {
                Text("OCR \(row.rawLengthText)  \(row.confidenceText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TallyBlockBreak: View {
    var nextJointText: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)

            Text("Jt \(nextJointText)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

private struct ProcessingOverlay: View {
    var message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .font(.headline)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    ScanPrototypeView()
}
