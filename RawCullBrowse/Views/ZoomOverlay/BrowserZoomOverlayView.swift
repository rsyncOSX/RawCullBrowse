import RawParserKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserZoomOverlayView: View {
    @Bindable var viewModel: FileBrowserViewModel

    private var copyAction: (() -> [NSItemProvider])? {
        guard let file = viewModel.selectedFile else { return nil }

        return {
            [NSItemProvider(object: file.url as NSURL)]
        }
    }

    private struct SubjectOutlineTaskID: Hashable {
        let fileID: BrowserFileItem.ID?
        let prompt: String?
        let isPresented: Bool
    }

    @State private var cropSource: RAW9CropSource?
    @State private var isPreparingCrop = false
    private let exportQueue = RAW9ExportQueue.shared
    @State private var rawExportError: String?
    @State private var isPickingWhiteBalance = false
    @State private var isSamplingWhiteBalance = false
    @State private var whiteBalanceTask: Task<Void, Never>?
    @State private var cameraTemperature: Double = 6500
    @State private var cameraTint: Double = 0
    @State private var raw9SupportedURL: URL?
    @State private var isEditingRAWAdjustment = false
    @State private var adjustmentRefreshTask: Task<Void, Never>?
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    @State private var lastMetadataOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    @State private var keyMonitor: Any?
    @State private var pendingInitialZoomMode: BrowserZoomInitialMode?
    @State private var viewportSize: CGSize = .zero
    @State private var subjectOutline: CGImage?
    @State private var showSubjectOutline = false
    @State private var isLoadingSubjectOutline = false

    private var subjectOutlineCandidate: DeepAIReviewCandidate? {
        guard let fileID = viewModel.selectedFile?.id else { return nil }
        return viewModel.deepAIReviewController.maskCandidate(for: fileID)
    }

    private var subjectOutlineTaskID: SubjectOutlineTaskID {
        SubjectOutlineTaskID(
            fileID: viewModel.selectedFile?.id,
            prompt: subjectOutlineCandidate?.maskPromptUsed?.rawValue,
            isPresented: showSubjectOutline,
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.98)
                .ignoresSafeArea()

            GeometryReader { geometry in
                if let image = viewModel.zoomImage {
                    ZStack {
                        Image(decorative: image, scale: 1.0, orientation: .up)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        if showSubjectOutline, !viewModel.useDevelopedRAW || viewModel.raw9Adjustments.crop == nil, let subjectOutline {
                            Image(decorative: subjectOutline, scale: 1, orientation: .up)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .colorMultiply(.orange)
                                .blendMode(.screen)
                                .opacity(0.95)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }

                        if viewModel.isZoomFocusPointVisible,
                           !viewModel.useDevelopedRAW || viewModel.raw9Adjustments.crop == nil,
                           let focusPoint = viewModel.zoomExifInfo?.focusPoint {
                            FocusPointMarker(
                                focusPoint: focusPoint,
                                imageSize: CGSize(width: image.width, height: image.height),
                                containerSize: geometry.size,
                            )
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(viewModel.zoomScale)
                    .offset(viewModel.zoomOffset)
                    .gesture(zoomPanGesture)
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        guard isPickingWhiteBalance else { return }
                        pickWhiteBalance(at: tap.location, image: image, containerSize: geometry.size)
                    })
                    .onAppear {
                        viewportSize = geometry.size
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: geometry.size,
                        )
                    }
                    .onChange(of: geometry.size) { _, size in
                        viewportSize = size
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: size,
                        )
                    }
                    .onChange(of: viewModel.zoomImage?.hashValue) { _, _ in
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: geometry.size,
                        )
                    }
                    .onChange(of: viewModel.zoomExifInfo?.focusPoint) { _, _ in
                        applyPendingInitialZoomIfNeeded(
                            imageSize: CGSize(width: image.width, height: image.height),
                            viewportSize: geometry.size,
                        )
                    }
                    .onTapGesture(count: 2) {
                        guard !isPickingWhiteBalance else { return }
                        withAnimation(.spring()) {
                            viewModel.zoomScale > 1.0 ? resetToFit() : zoomToTwoX()
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if viewModel.zoomImageError == nil {
                            ProgressView().controlSize(.large)
                        }
                        Text(viewModel.zoomImageError ?? "Loading image...")
                            .font(.title3)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            VStack {
                ZStack(alignment: .top) {
                    if viewModel.isZoomMetadataVisible {
                        ZoomMetadataPanel(
                            fileName: viewModel.selectedFile?.name,
                            exifInfo: viewModel.zoomExifInfo,
                            image: viewModel.zoomImage,
                            isCollapsed: $viewModel.isZoomMetadataCollapsed,
                        )
                        .offset(viewModel.zoomMetadataOffset)
                        .gesture(metadataDragGesture)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    HStack(spacing: 12) {
                        Button {
                            viewModel.navigateSelection(by: -1)
                        } label: {
                            Image(systemName: "chevron.left.circle")
                        }
                        .help("Previous image")

                        Button {
                            viewModel.navigateSelection(by: 1)
                        } label: {
                            Image(systemName: "chevron.right.circle")
                        }
                        .help("Next image")

                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help("Close")
                    }
                    .font(.title2)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                .padding()

                Spacer()

                VStack(spacing: 8) {
                    if isPickingWhiteBalance {
                        Text("Click a neutral white or gray area in the photo. Escape cancels.")
                            .font(.callout)
                            .padding(8)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if viewModel.useDevelopedRAW,
                       raw9SupportedURL != nil,
                       raw9SupportedURL == viewModel.selectedFile?.url {
                        centeredControlRow(height: 46) {
                            rawAdjustmentControls
                        }
                    }

                    centeredControlRow(height: 66) {
                        zoomControlRow
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }

            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled(true)
        .onCopyCommand(perform: copyAction)
        .onKeyPress(.leftArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 123,
                navigationAxis: viewModel.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.rightArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 124,
                navigationAxis: viewModel.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.upArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 126,
                navigationAxis: viewModel.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.downArrow) {
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: nil,
                keyCode: 125,
                navigationAxis: viewModel.zoomOverlayNavigationAxis,
            ))
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+-sSaAeExX")) { press in
            handleKeyAction(ZoomOverlayKeyAction.resolve(
                characters: press.characters,
                keyCode: 0,
                navigationAxis: viewModel.zoomOverlayNavigationAxis,
            ))
        }
        .onAppear {
            pendingInitialZoomMode = viewModel.zoomLaunchContext.initialZoomMode
            installKeyMonitor()
        }
        .onDisappear {
            adjustmentRefreshTask?.cancel()
            whiteBalanceTask?.cancel()
            removeKeyMonitor()
            subjectOutline = nil
            isLoadingSubjectOutline = false
        }
        .task(id: viewModel.selectedFile?.url) {
            adjustmentRefreshTask?.cancel()
            whiteBalanceTask?.cancel()
            isPickingWhiteBalance = false
            isSamplingWhiteBalance = false
            raw9SupportedURL = nil
            guard let url = viewModel.selectedFile?.url else { return }
            let supported = await RAW9Support.isSupported(for: url)
            guard !Task.isCancelled else { return }
            if supported, let balance = try? await viewModel.raw9WhiteBalance() {
                guard !Task.isCancelled, viewModel.selectedFile?.url == url else { return }
                cameraTemperature = balance.temperature
                cameraTint = balance.tint
            }
            raw9SupportedURL = supported ? url : nil
        }
        .onChange(of: viewModel.raw9Adjustments) {
            guard !isEditingRAWAdjustment else { return }
            scheduleRAWAdjustmentRefresh()
        }
        .task(id: subjectOutlineTaskID) {
            await loadSubjectOutline()
        }
    }

    private func scheduleRAWAdjustmentRefresh() {
        adjustmentRefreshTask?.cancel()
        guard viewModel.useDevelopedRAW,
              raw9SupportedURL == viewModel.selectedFile?.url, raw9SupportedURL != nil else { return }
        adjustmentRefreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            viewModel.refreshRAW9Preview()
        }
    }

    private func centeredControlRow(height: CGFloat, @ViewBuilder content: @escaping () -> some View) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                content()
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: height)
    }

    private var rawAdjustmentControls: some View {
        HStack(spacing: 8) {
            adjustmentSlider("Temp K", value: Binding(
                get: { viewModel.raw9Adjustments.temperature ?? cameraTemperature },
                set: { viewModel.raw9Adjustments.temperature = $0 },
            ), range: 2000 ... 50000, fractionDigits: 0)
            adjustmentSlider("Tint", value: Binding(
                get: { viewModel.raw9Adjustments.tint ?? cameraTint },
                set: { viewModel.raw9Adjustments.tint = $0 },
            ), range: -150 ... 150)
            Button {
                isPickingWhiteBalance.toggle()
            } label: {
                Label(isPickingWhiteBalance ? "Cancel picker" : "White balance", systemImage: "eyedropper")
            }
            .foregroundStyle(isPickingWhiteBalance ? .yellow : .secondary)
            .disabled(isSamplingWhiteBalance || viewModel.zoomImage == nil)
            .help("Click a neutral white or gray area to set white balance")
            adjustmentSlider("Exposure", value: $viewModel.raw9Adjustments.exposure, range: -3 ... 3)
            adjustmentSlider("Noise", value: $viewModel.raw9Adjustments.noiseReduction, range: -1 ... 1)
            adjustmentSlider("Sharpness", value: $viewModel.raw9Adjustments.sharpness, range: -1 ... 1)
            adjustmentSlider("Contrast", value: $viewModel.raw9Adjustments.contrast, range: -1 ... 1)
            Button("Crop", systemImage: "crop") { prepareCrop() }
                .disabled(isPreparingCrop)
                .sheet(item: $cropSource) { source in
                    RAW9CropEditor(source: source, viewModel: viewModel)
                }
            Menu {
                ForEach(RAW9PreviewRenderer.exportTypes, id: \.self) { identifier in
                    if let type = UTType(identifier) {
                        Button(type.localizedDescription ?? identifier) { exportRAW(type: type) }
                    }
                }
                Button("HEIF (10-bit)") { exportRAW(type: .heic, heif10: true) }
                if !RAW9PreviewRenderer.exportTypes.contains("com.ilm.openexr-image") {
                    Button("OpenEXR") {
                        exportRAW(type: UTType(filenameExtension: "exr") ?? UTType(exportedAs: "com.ilm.openexr-image"))
                    }
                }
            } label: {
                Label(exportQueue.outstandingCount > 0 ? "Export (\(exportQueue.outstandingCount))" : "Export", systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparingCrop)
            .help("Exports run in the background in request order, even after Zoom View closes.")
            .alert("RAW 9", isPresented: Binding(get: { rawExportError != nil || exportQueue.lastError != nil }, set: {
                if !$0 {
                    rawExportError = nil
                    exportQueue.lastError = nil
                }
            })) {
                Button("OK") { rawExportError = nil; exportQueue.lastError = nil }
            } message: { Text(rawExportError ?? exportQueue.lastError ?? "") }
            if let error = viewModel.raw9SidecarError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
                    .accessibilityLabel(error)
            }
            Button("Reset") {
                whiteBalanceTask?.cancel()
                isSamplingWhiteBalance = false
                isPickingWhiteBalance = false
                viewModel.raw9Adjustments = RAW9Adjustments()
            }
            .disabled(viewModel.raw9Adjustments == RAW9Adjustments())
        }
        .controlSize(.mini)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .tint(.white.opacity(0.65))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .help("RAW 9 adjustments are saved automatically to a sidecar beside the original. Noise, sharpness and contrast are offsets from camera defaults.")
    }

    private func prepareCrop() {
        guard let url = viewModel.selectedFile?.url else { return }
        isPickingWhiteBalance = false
        var adjustments = viewModel.raw9Adjustments
        adjustments.crop = nil
        isPreparingCrop = true
        Task {
            defer { isPreparingCrop = false }
            do {
                let image = try await RAW9PreviewRenderer().render(url: url, adjustments: adjustments)
                guard viewModel.selectedFile?.url == url else { return }
                cropSource = RAW9CropSource(url: url, image: image, crop: viewModel.raw9Adjustments.crop)
            } catch { rawExportError = error.localizedDescription }
        }
    }

    private func exportRAW(type: UTType, heif10: Bool = false) {
        guard let url = viewModel.selectedFile?.url else { return }
        let adjustments = viewModel.raw9Adjustments
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited." + (type.preferredFilenameExtension ?? "img")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            guard destination.resolvingSymlinksInPath() != url.resolvingSymlinksInPath(),
                  destination.resolvingSymlinksInPath() != RAW9SidecarStore.sidecarURL(for: url).resolvingSymlinksInPath()
            else {
                rawExportError = "Choose a destination other than the original RAW or its sidecar."
                return
            }
            exportQueue.enqueue(RAW9ExportJob(
                source: url, adjustments: adjustments, destination: destination,
                type: type.identifier, heif10: heif10,
            ))
        }
    }

    private func adjustmentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, fractionDigits: Int = 1) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(fractionDigits)))
                    .monospacedDigit()
            }
            .font(.caption2)
            Slider(value: value, in: range) { editing in
                isEditingRAWAdjustment = editing
                adjustmentRefreshTask?.cancel()
                if !editing {
                    scheduleRAWAdjustmentRefresh()
                }
            }
            .accessibilityLabel(title)
        }
        .frame(width: 78)
    }

    private var zoomControlRow: some View {
        HStack(spacing: 12) {
            Picker("", selection: $viewModel.useDevelopedRAW) {
                Text("JPG").tag(false)
                Text(raw9SupportedURL != nil && raw9SupportedURL == viewModel.selectedFile?.url ? "RAW 9" : "RAW").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .disabled(viewModel.selectedFile.map { SupportedFileType.isRenderedImage($0.url) } ?? true)
            .help("Show the embedded JPEG or develop the full-size RAW image. RAW 9 is preferred when supported.")
            .onChange(of: viewModel.useDevelopedRAW) {
                whiteBalanceTask?.cancel()
                isPickingWhiteBalance = false
                isSamplingWhiteBalance = false
                viewModel.openZoom()
            }
            Button { decreaseZoom() } label: {
                ZoomControlBadge {
                    Image(systemName: "minus.magnifyingglass")
                }
            }
            Button { withAnimation(.spring()) { resetToFit() } } label: {
                ZoomControlBadge {
                    Image(systemName: "1.magnifyingglass")
                }
            }
            Button { increaseZoom() } label: {
                ZoomControlBadge {
                    Image(systemName: "plus.magnifyingglass")
                }
            }
            Toggle(isOn: $viewModel.isZoomFocusPointVisible) {
                ZoomControlBadge(width: 62) {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isZoomFocusPointVisible ? "dot.circle.viewfinder" : "dot.viewfinder")
                            .foregroundStyle(viewModel.isZoomFocusPointVisible ? .yellow : .primary)
                            .symbolEffect(.bounce, value: viewModel.isZoomFocusPointVisible)

                        Text("A")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .toggleStyle(.button)
            .disabled(viewModel.zoomExifInfo?.focusPoint == nil)
            .accessibilityLabel("Focus Point")
            .help(viewModel.zoomExifInfo?.focusPoint == nil ? "No focus point found in EXIF data" : "Show focus point")

            Toggle(isOn: $showSubjectOutline) {
                ZoomControlBadge(width: 62) {
                    HStack(spacing: 6) {
                        if isLoadingSubjectOutline {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: showSubjectOutline ? "person.crop.circle.fill" : "person.crop.circle")
                                .foregroundStyle(showSubjectOutline ? .orange : .primary)
                        }

                        Text("S")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .toggleStyle(.button)
            .disabled(subjectOutlineCandidate == nil)
            .accessibilityLabel("Subject Outline")
            .help(subjectOutlineCandidate == nil ? "Run Deep Review for this image first" : "Show Deep Review subject outline (S)")
        }
    }

    private func pickWhiteBalance(at location: CGPoint, image: CGImage, containerSize: CGSize) {
        guard !isSamplingWhiteBalance, let url = viewModel.selectedFile?.url,
              viewModel.useDevelopedRAW, raw9SupportedURL == url else { return }
        // The tap is in the image container's local coordinates, before zoom and pan.
        let scale = min(containerSize.width / CGFloat(image.width), containerSize.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        var point = CGPoint(x: (location.x - origin.x) / size.width, y: (location.y - origin.y) / size.height)
        guard (0 ... 1).contains(point.x), (0 ... 1).contains(point.y) else { return }
        if let crop = viewModel.raw9Adjustments.crop {
            point = CGPoint(x: crop.x + point.x * crop.width, y: crop.y + point.y * crop.height)
        }
        isPickingWhiteBalance = false
        isSamplingWhiteBalance = true
        let originalAdjustments = viewModel.raw9Adjustments
        whiteBalanceTask = Task {
            defer { isSamplingWhiteBalance = false }
            do {
                let balance = try await viewModel.raw9WhiteBalance(normalizedPoint: point)
                guard !Task.isCancelled, viewModel.selectedFile?.url == url,
                      viewModel.useDevelopedRAW, viewModel.raw9Adjustments == originalAdjustments else { return }
                var adjustments = originalAdjustments
                adjustments.temperature = balance.temperature
                adjustments.tint = balance.tint
                viewModel.raw9Adjustments = adjustments
            } catch {
                guard !Task.isCancelled, viewModel.selectedFile?.url == url else { return }
                viewModel.raw9SidecarError = "Could not sample white balance: \(error.localizedDescription)"
            }
        }
    }

    private var zoomPanGesture: some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    viewModel.zoomScale = min(max(lastScale * value.magnification, 0.5), 5.0)
                }
                .onEnded { _ in
                    lastScale = viewModel.zoomScale
                    if viewModel.zoomScale < 1.0 {
                        withAnimation(.spring()) { resetToFit() }
                    }
                },
            DragGesture()
                .onChanged { value in
                    guard viewModel.zoomScale > 1.0 else { return }
                    viewModel.zoomOffset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height,
                    )
                }
                .onEnded { _ in
                    lastOffset = viewModel.zoomOffset
                },
        )
    }

    private var metadataDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                viewModel.zoomMetadataOffset = CGSize(
                    width: lastMetadataOffset.width + value.translation.width,
                    height: lastMetadataOffset.height + value.translation.height,
                )
            }
            .onEnded { _ in
                lastMetadataOffset = viewModel.zoomMetadataOffset
            }
    }

    private func increaseZoom() {
        withAnimation(.spring()) {
            viewModel.zoomScale = min(viewModel.zoomScale + 0.25, 5.0)
            lastScale = viewModel.zoomScale
        }
    }

    private func toggleFocusPoint() {
        guard viewModel.zoomExifInfo?.focusPoint != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.isZoomFocusPointVisible.toggle()
        }
    }

    private func decreaseZoom() {
        withAnimation(.spring()) {
            viewModel.zoomScale = max(viewModel.zoomScale - 0.25, 0.5)
            lastScale = viewModel.zoomScale
            if viewModel.zoomScale <= 1.0 {
                viewModel.zoomOffset = .zero
                lastOffset = .zero
            }
        }
    }

    private func zoomToTwoX() {
        viewModel.zoomScale = 2.0
        lastScale = 2.0
    }

    private func resetToFit() {
        viewModel.zoomScale = 1.0
        lastScale = 1.0
        viewModel.zoomOffset = .zero
        lastOffset = .zero
    }

    private func applyPendingInitialZoomIfNeeded(imageSize: CGSize, viewportSize: CGSize) {
        guard pendingInitialZoomMode == .actualPixels,
              viewportSize.width > 0,
              viewportSize.height > 0
        else { return }
        if viewModel.zoomLaunchContext.showFocusPointOnOpen,
           !viewModel.isZoomExifInfoLoaded {
            return
        }
        applyActualPixelsZoom(imageSize: imageSize, viewportSize: viewportSize)
        pendingInitialZoomMode = nil
    }

    private func applyActualPixelsZoom(imageSize: CGSize, viewportSize: CGSize) {
        let transform = BrowserZoomViewportMath.actualPixelsTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
            normalizedFocusPoint: normalizedFocusPoint,
        )
        viewModel.zoomScale = transform.scale
        lastScale = transform.scale
        viewModel.zoomOffset = transform.offset
        lastOffset = transform.offset
        viewModel.isZoomFocusPointVisible = viewModel.zoomExifInfo?.focusPoint != nil
    }

    private var normalizedFocusPoint: CGPoint? {
        guard let focusPoint = viewModel.zoomExifInfo?.focusPoint else { return nil }
        return CGPoint(x: CGFloat(focusPoint.normalizedX), y: CGFloat(focusPoint.normalizedY))
    }

    private func close() {
        viewModel.closeZoom()
    }

    private func handleKeyAction(_ action: ZoomOverlayKeyAction?) -> KeyPress.Result {
        guard cropSource == nil, !isPreparingCrop, NSApp.keyWindow?.attachedSheet == nil,
              let action else { return .ignored }

        switch action {
        case .navigatePrevious:
            viewModel.navigateSelection(by: -1)
            return .handled

        case .navigateNext:
            viewModel.navigateSelection(by: 1)
            return .handled

        case .escape:
            dismiss()
            return .handled

        case .zoomIn:
            increaseZoom()
            return .handled

        case .zoomOut:
            decreaseZoom()
            return .handled

        case .toggleSubjectOutline:
            guard subjectOutlineCandidate != nil else { return .ignored }
            showSubjectOutline.toggle()
            return .handled

        case .toggleMetadata:
            viewModel.isZoomMetadataVisible.toggle()
            return .handled

        case .toggleFocusPoints:
            toggleFocusPoint()
            return .handled
        }
    }

    private func dismiss() {
        if isPickingWhiteBalance {
            isPickingWhiteBalance = false
            return
        }
        viewModel.closeZoom()
        resetToFit()
        subjectOutline = nil
    }

    private func loadSubjectOutline() async {
        subjectOutline = nil
        isLoadingSubjectOutline = false
        guard showSubjectOutline,
              let file = viewModel.selectedFile,
              let candidate = subjectOutlineCandidate
        else { return }

        isLoadingSubjectOutline = true
        let mask = await viewModel.deepAIReviewController.mask(
            for: candidate,
            in: [file],
        )
        guard !Task.isCancelled,
              viewModel.selectedFile?.id == file.id
        else {
            isLoadingSubjectOutline = false
            return
        }

        if let mask {
            subjectOutline = await DeepAIReviewMaskOutlineRenderer.outline(from: mask) ?? mask
        }
        guard !Task.isCancelled,
              viewModel.selectedFile?.id == file.id
        else {
            subjectOutline = nil
            isLoadingSubjectOutline = false
            return
        }
        isLoadingSubjectOutline = false
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard viewModel.zoomOverlayVisible,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }

            return handleKeyEvent(event) == .handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> KeyPress.Result {
        handleKeyAction(ZoomOverlayKeyAction.resolve(
            characters: event.characters,
            keyCode: event.keyCode,
            navigationAxis: viewModel.zoomOverlayNavigationAxis,
        ))
    }
}
