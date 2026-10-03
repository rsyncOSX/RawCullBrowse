import CoreAICLIPBackend
import CoreGraphics
import Foundation
import Observation
import RawParserKit

@Observable @MainActor
final class FileBrowserViewModel {
    isolated deinit {
        // Release any session grants still held when the browser is discarded.
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }

    static let defaultQwenPrompt = "Evaluate the composition, exposure, subject visibility, expression, and obstructions."

    let deepAIReviewController = DeepAIReviewController()

    var rootFolders: [BrowserFolderItem] = []
    var folderChildren: [BrowserFolderItem.ID: [BrowserFolderItem]] = [:]
    var expandedFolderIDs: Set<BrowserFolderItem.ID> = []
    var loadingFolderIDs: Set<BrowserFolderItem.ID> = []
    var files: [BrowserFileItem] = []
    var selectedFolder: BrowserFolderItem?
    var selectedFileID: BrowserFileItem.ID?
    var selectedFileIDs: Set<BrowserFileItem.ID> = []
    var isShowingFolderPicker = false
    var isShowingClearCatalogConfirmation = false
    var isScanning = false
    var isCreatingThumbnails = false
    var zoomOverlayVisible = false
    var raw9Adjustments = RAW9Adjustments() {
        didSet {
            guard !isRestoringRAW9Adjustments, raw9Adjustments != oldValue,
                  let url = raw9AdjustmentURL else { return }
            scheduleRAW9SidecarSave(for: url)
        }
    }

    /// Session memory survives navigation and closing/reopening the zoom overlay.
    var copiedRAW9Adjustments: RAW9Adjustments?

    func copyRAW9Adjustments() {
        copiedRAW9Adjustments = raw9Adjustments
    }

    func pasteRAW9Adjustments() {
        guard let adjustments = copiedRAW9Adjustments,
              let url = selectedFile?.url, raw9AdjustmentURL == url else { return }
        // A pending sidecar read must not replace pasted values, including defaults.
        raw9LoadedSidecarURL = url
        isRestoringRAW9Adjustments = true
        raw9Adjustments = adjustments
        isRestoringRAW9Adjustments = false
        scheduleRAW9SidecarSave(for: url)
        useDevelopedRAW = true
        refreshRAW9Preview()
    }

    private func scheduleRAW9SidecarSave(for url: URL) {
        let adjustments = raw9Adjustments
        let previousSave = raw9SidecarSaveTask
        if raw9SidecarSaveURL == url {
            previousSave?.cancel()
        }
        raw9SidecarSaveURL = url
        // Coalesce drag events, preserve write order across files, and finish
        // the final save even after navigating away or closing zoom.
        raw9SidecarSaveTask = Task {
            await previousSave?.value
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                try await raw9SidecarStore.save(adjustments, for: url)
                if raw9AdjustmentURL == url {
                    raw9SidecarError = nil
                }
            } catch is CancellationError {
                return
            } catch {
                if raw9AdjustmentURL == url {
                    raw9SidecarError = "Could not save RAW 9 sidecar: \(error.localizedDescription)"
                }
            }
        }
    }

    var raw9SidecarError: String?
    private var isRestoringRAW9Adjustments = false
    private let raw9SidecarStore = RAW9SidecarStore()
    private var raw9SidecarSaveTask: Task<Void, Never>?
    private var raw9SidecarSaveURL: URL?
    private var raw9AdjustmentURL: URL?
    private var raw9LoadedSidecarURL: URL?
    private let raw9Renderer = RAW9PreviewRenderer()
    var rawPreviewBitDepth: RAWPreviewBitDepth {
        get { settings.rawPreviewBitDepth }
        set {
            guard settings.rawPreviewBitDepth != newValue else { return }
            settings.rawPreviewBitDepth = newValue
            persistSettings()
            if zoomOverlayVisible, useDevelopedRAW, raw9LoadedSidecarURL == selectedFile?.url {
                refreshRAW9Preview()
            }
        }
    }

    var useDevelopedRAW = false
    var zoomImageError: String?
    var zoomImage: CGImage?
    var zoomExifInfo: RawImageMetadata?
    var isZoomExifInfoLoaded = false
    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var isZoomMetadataVisible = true
    var isZoomMetadataCollapsed = false
    var zoomMetadataOffset: CGSize = .zero
    var isZoomFocusPointVisible = false
    var zoomLaunchContext: BrowserZoomLaunchContext = .default
    var settings = BrowserSettings()
    var clipModelStatus: CLIPModelStatus = .notConfigured
    var clipIndexStatus: CLIPIndexStatus = .noFolderSelected
    var isIndexing = false
    var indexingProgress: CLIPIndexingProgress?
    var lastIndexSummary: CLIPIndexSummary?
    var semanticSearchQuery = ""
    var semanticSearchResults: [CLIPSearchResult] = []
    var semanticSearchActive = false
    var similaritySearchAnchorName: String?
    var isSearching = false


    var hasCompatibleCLIPIndex = false
    var clipFeatureError: String?
    var qwenPrompt = defaultQwenPrompt
    var qwenResults: [QwenPhotoAnalysisResult] = []
    var qwenProgress: QwenBatchProgress?
    var qwenFeatureError: String?
    var isQwenResponding = false
    private(set) var qwenModelStatus: QwenModelStatus = .notConfigured
    private(set) var sam3ModelStatus: RawCullBrowseAICapabilityStatus = .missing(expectedLocations: [])
    private(set) var clipModelDownloadStates: [CLIPModelDownloadID: CLIPModelDownloadState] =
        Dictionary(uniqueKeysWithValues: CLIPModelDownloadID.allCases.map { ($0, .checking) })

    var zoomOverlayNavigationAxis: ZoomOverlayNavigationAxis = .horizontal

    @ObservationIgnored private var activeSecurityScopedURL: URL?
    @ObservationIgnored private var activeCLIPModelURL: URL?
    @ObservationIgnored private var activeSAM3ModelURL: URL?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var zoomTask: Task<Void, Never>?
    @ObservationIgnored private var scanID = UUID()
    @ObservationIgnored private var selectionAnchorFileID: BrowserFileItem.ID?
    @ObservationIgnored private var rememberedCatalogs: [URL: RememberedCatalog] = [:]
    @ObservationIgnored private let clipModelManager = CLIPModelManager()
    @ObservationIgnored private let clipModelDownloadCoordinator = CLIPModelDownloadCoordinator()
    @ObservationIgnored private let deepAIReviewRuntime = DeepAIReviewRuntime()
    @ObservationIgnored private let qwenModelManager = QwenModelManager()
    @ObservationIgnored private var managedCLIPModelLocations: [CLIPModelDownloadID: URL] = [:]
    @ObservationIgnored private var clipModelDownloadTasks: [CLIPModelDownloadID: Task<Void, Never>] = [:]
    @ObservationIgnored private var clipModelRefreshGeneration = 0
    @ObservationIgnored private var clipProvider: CoreAICLIPProvider?
    @ObservationIgnored private var clipEngine: CLIPSearchEngine?
    @ObservationIgnored private var clipEngineDirectoryURL: URL?
    @ObservationIgnored private var modelValidationTask: Task<Void, Never>?
    @ObservationIgnored private var sam3ValidationTask: Task<Void, Never>?
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var indexValidationTask: Task<Void, Never>?
    @ObservationIgnored private var catalogCLIPIndexes: [URL: (engine: CLIPSearchEngine, status: CLIPIndexStatus)] = [:]
    @ObservationIgnored private var catalogIndexValidationTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var qwenValidationTask: Task<Void, Never>?
    @ObservationIgnored private var qwenResponseTask: Task<Void, Never>?
    @ObservationIgnored private var qwenRequestID = UUID()
    @ObservationIgnored private var activeQwenModelURL: URL?
    private var semanticFiles: [BrowserFileItem] = []
    @ObservationIgnored private var indexingID = UUID()
    @ObservationIgnored private var indexValidationID = UUID()
    @ObservationIgnored private var searchID = UUID()

    var displayedFiles: [BrowserFileItem] {
        semanticSearchActive ? semanticFiles : files
    }

    var isShowingSemanticResults: Bool {
        semanticSearchActive
    }

    var isShowingSimilarityResults: Bool {
        similaritySearchAnchorName != nil
    }

    var activeCLIPModelName: String {
        guard case let .available(_, _, modelName) = clipModelStatus else {
            return settings.selectedCLIPModel.displayName
        }
        return modelName
    }

    var semanticSearchLimit: Int {
        settings.semanticSearchLimit
    }

    /// File operations retain the granted catalog root, even for a child folder.
    var catalogAccessURL: URL? {
        guard let folderURL = selectedFolder?.url else { return nil }
        return securityScopedURL(for: folderURL)
    }

    /// Search and indexing use the catalog root even when a child folder is selected.
    var clipCatalogURL: URL? {
        catalogAccessURL?.standardizedFileURL
    }

    var canIndexSelectedFolder: Bool {
        selectedFolder != nil
            && clipProvider != nil
            && !isIndexing
            && !isSearching
    }

    var canSearch: Bool {
        hasCompatibleCLIPIndex
            && clipEngine != nil
            && !isIndexing
            && !isSearching
    }

    var canFindSimilar: Bool {
        selectedFile != nil && canSearch
    }

    var canDeepReviewSelection: Bool {
        shouldPresentDeepReviewAction
            && !deepAIReviewController.isActionUnavailable
    }

    var shouldPresentDeepReviewAction: Bool {
        !selectedFileIDs.isEmpty
            && sam3ModelStatus.isAvailable
    }

    var canAskQwen: Bool {
        qwenModelStatus.isAvailable
            && !selectedFiles.isEmpty
            && !isQwenResponding
            && !qwenPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedFile: BrowserFileItem? {
        displayedFiles.first { $0.id == selectedFileID }
    }

    var selectedFiles: [BrowserFileItem] {
        displayedFiles.filter { selectedFileIDs.contains($0.id) }
    }

    var isSidebarSelectionEnabled: Bool {
        !isCreatingThumbnails
    }

    var title: String {
        guard let selectedFolder else { return "RawCullBrowse" }
        if isShowingSemanticResults {
            if let similaritySearchAnchorName {
                return "Similar to \(similaritySearchAnchorName) (\(semanticSearchResults.count) results)"
            }
            return "Semantic Search (\(semanticSearchResults.count) results)"
        }
        return "\(selectedFolder.name) (\(files.count) files)"
    }

    func loadSettings() async {
        settings = await BrowserSettingsStore.load()
        // Downloaded models are the only model source. Drop legacy folder overrides.
        settings.clipModelPath = nil
        settings.clipModelBookmarkData = nil
        settings.qwenModelPath = nil
        settings.qwenModelBookmarkData = nil
        settings.sam3ModelPath = nil
        settings.sam3ModelBookmarkData = nil
        persistSettings()
        await MemoryImageCache.shared.apply(settings: settings)
        activateSavedQwenModel()
        await refreshCLIPModels()
    }

    func askQwen() {
        let prompt = qwenPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAskQwen, !prompt.isEmpty else { return }
        let files = selectedFiles
        let previewSize = min(settings.thumbnailSizePreview, 2048)

        qwenResponseTask?.cancel()
        qwenRequestID = UUID()
        let requestID = qwenRequestID
        qwenFeatureError = nil
        qwenResults = []
        qwenProgress = QwenBatchProgress(
            completedCount: 0,
            totalCount: files.count,
            currentFileName: files.first?.name,
        )
        isQwenResponding = true
        qwenResponseTask = Task { [weak self] in
            guard let self else { return }
            var completed: [QwenPhotoAnalysisResult] = []
            for (index, file) in files.enumerated() {
                if Task.isCancelled || qwenRequestID != requestID {
                    break
                }
                qwenProgress = QwenBatchProgress(
                    completedCount: completed.count,
                    totalCount: files.count,
                    currentFileName: file.name,
                )
                do {
                    guard let image = await RawImageLoader.shared.previewImage(
                        for: file.url,
                        maxPixelSize: previewSize,
                    ) else {
                        throw QwenModelError.imageUnavailable
                    }
                    try Task.checkCancellation()
                    let assessment = try await qwenModelManager.assess(
                        criteria: prompt,
                        image: image,
                    )
                    try Task.checkCancellation()
                    completed.append(QwenPhotoAnalysisResult(
                        fileID: file.id,
                        fileName: file.name,
                        assessment: assessment,
                        failure: nil,
                    ))
                } catch is CancellationError {
                    break
                } catch {
                    completed.append(QwenPhotoAnalysisResult(
                        fileID: file.id,
                        fileName: file.name,
                        assessment: nil,
                        failure: error.localizedDescription,
                    ))
                }
                guard qwenRequestID == requestID else { return }
                qwenResults = completed
                let nextName = files.indices.contains(index + 1) ? files[index + 1].name : nil
                qwenProgress = QwenBatchProgress(
                    completedCount: completed.count,
                    totalCount: files.count,
                    currentFileName: nextName,
                )
            }
            guard qwenRequestID == requestID else { return }
            qwenResults = completed
            qwenProgress = nil
            if !completed.isEmpty, completed.allSatisfy({ $0.assessment == nil }) {
                qwenFeatureError = "Qwen could not analyze any of the selected photos."
            }
            isQwenResponding = false
            qwenResponseTask = nil
        }
    }

    func cancelQwenRequest() {
        qwenRequestID = UUID()
        qwenResponseTask?.cancel()
        qwenResponseTask = nil
        qwenProgress = nil
        isQwenResponding = false
    }

    func startDeepReview(
        groupID: Int,
        groupSignature: BurstGroupSignature,
        files: [BrowserFileItem],
    ) async {
        let preparationFiles = deepAIReviewController.scope == .fast
            ? Array(files.prefix(8))
            : files
        let labels = await (try? clipEngine?.classifySubjects(
            in: preparationFiles.map(\.url),
        )) ?? [:]
        var candidates: [DeepAIReviewInputCandidate] = []
        candidates.reserveCapacity(preparationFiles.count)

        for (index, file) in preparationFiles.enumerated() {
            guard !Task.isCancelled else { return }
            async let metadata = RawImageLoader.shared.metadata(for: file.url)
            async let thumbnail = RawImageLoader.shared.thumbnail(for: file.url, targetSize: 1024)
            let (loadedMetadata, loadedThumbnail) = await (metadata, thumbnail)
            let focusPoint = loadedMetadata?.focusPoint.map {
                CGPoint(x: CGFloat($0.normalizedX), y: CGFloat($0.normalizedY))
            }
            let sharpness = loadedThumbnail.flatMap {
                $0.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }.flatMap(WholeImageSharpnessScorer.score)
            candidates.append(DeepAIReviewInputCandidate(
                fileID: file.id,
                fileName: file.name,
                url: file.url,
                burstRank: index + 1,
                normalSharpnessScore: sharpness,
                subjectLabel: labels[file.url.standardizedFileURL],
                normalizedAFPoint: focusPoint,
            ))
        }

        await deepAIReviewController.start(
            groupID: groupID,
            groupSignature: groupSignature,
            candidates: candidates,
        )
    }

    func refreshCLIPModels() async {
        clipModelRefreshGeneration &+= 1
        let generation = clipModelRefreshGeneration
        let snapshot = await clipModelDownloadCoordinator.snapshot()
        guard !Task.isCancelled, clipModelRefreshGeneration == generation else { return }
        managedCLIPModelLocations = snapshot.managedModelLocations
        clipModelDownloadStates = snapshot.states
        activateSelectedCLIPModel()
        activateSelectedSAM3Model()
        activateSavedQwenModel()
    }

    func acceptModelLicence(_ id: CLIPModelDownloadID) async {
        do {
            try await clipModelDownloadCoordinator.acceptLicence(
                for: id,
                rawCullBrowseVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            )
            await refreshCLIPModels()
        } catch {
            clipModelDownloadStates[id] = .failed(message: error.localizedDescription)
        }
    }

    func startCLIPModelDownload(_ id: CLIPModelDownloadID) {
        guard clipModelDownloadTasks[id] == nil,
              clipModelDownloadStates[id]?.canStartDownload == true
        else { return }

        clipModelDownloadStates[id] = .downloading(progress: 0)
        clipModelDownloadTasks[id] = Task { [weak self] in
            guard let self else { return }
            await performCLIPModelDownload(id)
        }
    }

    func cancelCLIPModelDownload(_ id: CLIPModelDownloadID) {
        clipModelDownloadTasks[id]?.cancel()
    }

    func removeManagedCLIPModel(_ id: CLIPModelDownloadID) async {
        guard clipModelDownloadTasks[id] == nil else { return }
        clipModelDownloadStates[id] = .removing
        do {
            try await clipModelDownloadCoordinator.remove(id)
            managedCLIPModelLocations[id] = nil
            if id == settings.selectedCLIPModel.downloadID {
                deactivateCLIPModelRuntime()
            }
            await refreshCLIPModels()
        } catch is CancellationError {
            return
        } catch {
            clipModelDownloadStates[id] = .failed(message: String(describing: error))
        }
    }

    func adjustSemanticSearchLimit(by delta: Int) {
        let adjusted = min(max(settings.semanticSearchLimit + delta, 10), 500)
        guard adjusted != settings.semanticSearchLimit else { return }
        settings.semanticSearchLimit = adjusted
        persistSettings()
        if !semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           hasCompatibleCLIPIndex {
            startSemanticSearch()
        }
    }

    func startIndexingSelectedFolder() {
        guard let directory = clipCatalogURL,
              let provider = clipProvider
        else {
            clipFeatureError = CLIPFeatureError.modelNotConfigured.description
            return
        }

        indexingTask?.cancel()
        indexValidationTask?.cancel()
        searchTask?.cancel()
        let operationID = UUID()
        indexingID = operationID
        indexValidationID = UUID()
        let engine = makeCLIPEngine(provider: provider, directory: directory)
        clipEngine = engine
        clipEngineDirectoryURL = directory
        hasCompatibleCLIPIndex = false
        clipIndexStatus = .checking(directory)
        isIndexing = true
        indexingProgress = nil
        lastIndexSummary = nil
        clipFeatureError = nil
        clearSemanticSearchResults(keepingQuery: true)

        indexingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await engine.synchronize(directory: directory) { [weak self] progress in
                    await self?.publishIndexingProgress(progress, operationID: operationID)
                }
                try Task.checkCancellation()
                guard self.indexingID == operationID else { return }
                self.lastIndexSummary = summary
                self.settings.lastIndexedDirectoryPath = directory.path
                self.persistSettings()
            } catch is CancellationError {
                // Cancellation is user initiated or caused by a replacement index operation.
            } catch {
                guard !Task.isCancelled, self.indexingID == operationID else { return }
                self.clipFeatureError = String(describing: error)
            }
            guard self.indexingID == operationID else { return }
            self.isIndexing = false
            self.indexingProgress = nil
            self.indexingTask = nil
            self.validateSelectedFolderCLIPIndex()
        }
    }

    func cancelIndexing() {
        indexingID = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        isIndexing = false
        indexingProgress = nil
        validateSelectedFolderCLIPIndex()
    }

    func validateSelectedFolderCLIPIndex() {
        guard let directory = clipCatalogURL else {
            clipIndexStatus = .noFolderSelected
            hasCompatibleCLIPIndex = false
            return
        }
        validateCatalogCLIPIndex(at: directory)
    }

    private func validateCatalogCLIPIndex(at directory: URL) {
        guard let provider = clipProvider else {
            if clipCatalogURL == directory {
                clipIndexStatus = .modelRequired
                hasCompatibleCLIPIndex = false
            }
            return
        }
        catalogIndexValidationTasks[directory]?.cancel()
        let engine = makeCLIPEngine(provider: provider, directory: directory)
        catalogCLIPIndexes[directory] = (engine, .checking(directory))
        if clipCatalogURL == directory {
            useCatalogCLIPIndex(at: directory)
        }
        let task = Task { [weak self] in
            let status = await engine.validateIndex(directory: directory)
            guard let self, !Task.isCancelled else { return }
            self.catalogCLIPIndexes[directory] = (engine, status)
            if let indexFileExists = status.indexFileExists {
                self.setCLIPIndexPresence(indexFileExists, for: directory)
            }
            if self.clipCatalogURL == directory {
                self.useCatalogCLIPIndex(at: directory)
                if status.allowsSearch {
                    self.settings.lastIndexedDirectoryPath = directory.path
                    self.persistSettings()
                } else {
                    self.clearSemanticSearchResults(keepingQuery: true)
                }
            }
            self.catalogIndexValidationTasks[directory] = nil
            if self.clipCatalogURL == directory {
                self.indexValidationTask = nil
            }
        }
        catalogIndexValidationTasks[directory] = task
        if clipCatalogURL == directory {
            indexValidationTask = task
        }
    }

    private func useCatalogCLIPIndex(at directory: URL) {
        guard let cached = catalogCLIPIndexes[directory] else {
            validateCatalogCLIPIndex(at: directory)
            return
        }
        clipEngine = cached.engine
        clipEngineDirectoryURL = directory
        clipIndexStatus = cached.status
        hasCompatibleCLIPIndex = cached.status.allowsSearch
        indexValidationTask = catalogIndexValidationTasks[directory]
    }

    private func clearCatalogCLIPIndexes() {
        for task in catalogIndexValidationTasks.values {
            task.cancel()
        }
        catalogIndexValidationTasks.removeAll()
        catalogCLIPIndexes.removeAll()
    }

    func startSemanticSearch() {
        let query = semanticSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSemanticSearchResults()
            return
        }
        guard let engine = clipEngine, hasCompatibleCLIPIndex else {
            clipFeatureError = CLIPFeatureError.missingCompatibleIndex.description
            return
        }

        searchTask?.cancel()
        let operationID = UUID()
        searchID = operationID
        isSearching = true
        clipFeatureError = nil
        semanticSearchActive = true
        similaritySearchAnchorName = nil
        semanticSearchResults = []
        semanticFiles = []
        let limit = settings.semanticSearchLimit
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.searchID == operationID {
                    self.isSearching = false
                    self.searchTask = nil
                }
            }
            do {
                let results = try await engine.search(text: query, limit: limit)
                try Task.checkCancellation()
                guard self.searchID == operationID else { return }
                self.semanticSearchResults = results
                self.semanticFiles = results.map { BrowserFileItem(url: $0.url) }
                self.selectedFileID = self.semanticFiles.first?.id
                self.selectedFileIDs = Set(self.semanticFiles.first.map { [$0.id] } ?? [])
                self.selectionAnchorFileID = self.semanticFiles.first?.id
            } catch is CancellationError {
                // A newer query owns result publication.
            } catch {
                guard !Task.isCancelled, self.searchID == operationID else { return }
                self.clipFeatureError = String(describing: error)
                self.clearSemanticSearchResults(keepingQuery: true)
            }
        }
    }

    func startSimilaritySearch() {
        guard let anchor = selectedFile else { return }
        guard let engine = clipEngine, hasCompatibleCLIPIndex else {
            clipFeatureError = CLIPFeatureError.missingCompatibleIndex.description
            return
        }

        searchTask?.cancel()
        let operationID = UUID()
        searchID = operationID
        isSearching = true
        clipFeatureError = nil
        semanticSearchActive = true
        similaritySearchAnchorName = anchor.name
        semanticSearchResults = []
        semanticFiles = []
        let limit = settings.semanticSearchLimit
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.searchID == operationID {
                    self.isSearching = false
                    self.searchTask = nil
                }
            }
            do {
                let results = try await engine.search(similarTo: anchor.url, limit: limit)
                try Task.checkCancellation()
                guard self.searchID == operationID else { return }
                self.semanticSearchResults = results
                self.semanticFiles = results.map { BrowserFileItem(url: $0.url) }
                self.selectedFileID = self.semanticFiles.first?.id
                self.selectedFileIDs = Set(self.semanticFiles.first.map { [$0.id] } ?? [])
                self.selectionAnchorFileID = self.semanticFiles.first?.id
            } catch is CancellationError {
                // A newer search owns result publication.
            } catch {
                guard !Task.isCancelled, self.searchID == operationID else { return }
                self.clipFeatureError = String(describing: error)
                self.clearSemanticSearchResults(keepingQuery: true)
            }
        }
    }

    func clearSemanticSearchResults(keepingQuery: Bool = false) {
        searchID = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        semanticSearchResults = []
        semanticSearchActive = false
        similaritySearchAnchorName = nil
        semanticFiles = []
        if !keepingQuery {
            semanticSearchQuery = ""
        }
        selectedFileID = files.first?.id
        selectedFileIDs = Set(files.first.map { [$0.id] } ?? [])
        selectionAnchorFileID = files.first?.id
    }

    func loadRememberedCatalogs() async {
        let catalogs = await RememberedCatalogStore.load()
        var loadedCatalogs: [URL: RememberedCatalog] = [:]
        var loadedFolders: [BrowserFolderItem] = []

        for catalog in catalogs {
            guard let url = RememberedCatalogStore.resolvedURL(for: catalog) else { continue }
            let standardizedURL = url.standardizedFileURL
            guard startSecurityScopedAccess(for: standardizedURL) else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                stopActiveSecurityScopedAccess()
                continue
            }

            loadedCatalogs[standardizedURL] = catalog
            let loadedFolder = await RawImageLoader.shared.folderItem(at: standardizedURL)
            loadedFolders.append(loadedFolder)
        }

        rememberedCatalogs = loadedCatalogs
        rootFolders = uniqueFolders(loadedFolders)
        await loadChildren(for: rootFolders)
        for folder in rootFolders {
            validateCatalogCLIPIndex(at: folder.url.standardizedFileURL)
        }

        if selectedFolder == nil, let firstCatalog = rootFolders.first {
            selectFolder(firstCatalog)
        }
    }

    func addRootFolder(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard startSecurityScopedAccess(for: standardizedURL) else { return }
        let folder = BrowserFolderItem(url: standardizedURL)
        if !rootFolders.contains(where: { $0.url == standardizedURL }) {
            rootFolders.append(folder)
            Task {
                let discoveredFolder = await RawImageLoader.shared.folderItem(at: standardizedURL)
                guard let rootIndex = rootFolders.firstIndex(where: { $0.id == discoveredFolder.id }) else {
                    return
                }
                rootFolders[rootIndex] = discoveredFolder
                if selectedFolder?.id == discoveredFolder.id {
                    selectedFolder = discoveredFolder
                }
                await loadChildren(for: [discoveredFolder])
            }
        }
        rememberCatalog(at: standardizedURL)
        catalogCLIPIndexes[standardizedURL] = nil
        selectFolder(folder)
    }

    func children(of folder: BrowserFolderItem) -> [BrowserFolderItem] {
        folderChildren[folder.id] ?? []
    }

    func hasLoadedChildren(for folder: BrowserFolderItem) -> Bool {
        folderChildren[folder.id] != nil
    }

    func isFolderExpanded(_ folder: BrowserFolderItem) -> Bool {
        expandedFolderIDs.contains(folder.id)
    }

    func setFolder(_ folder: BrowserFolderItem, expanded: Bool) {
        if expanded {
            expandedFolderIDs.insert(folder.id)
            loadChildrenIfNeeded(for: folder)
        } else {
            expandedFolderIDs.remove(folder.id)
        }
    }

    var visibleSidebarFolders: [BrowserFolderItem] {
        var folders: [BrowserFolderItem] = []

        func appendVisibleFolder(_ folder: BrowserFolderItem) {
            folders.append(folder)
            guard isFolderExpanded(folder) else { return }
            children(of: folder).forEach(appendVisibleFolder)
        }

        rootFolders.forEach(appendVisibleFolder)
        return folders
    }

    @discardableResult
    func moveSidebarSelection(by offset: Int) -> Bool {
        guard isSidebarSelectionEnabled, offset != 0 else { return false }

        let folders = visibleSidebarFolders
        guard !folders.isEmpty else { return false }

        let destinationIndex: Int = if let selectedFolder,
                                       let selectedIndex = folders.firstIndex(where: { $0.id == selectedFolder.id }) {
            selectedIndex + offset
        } else {
            offset > 0 ? folders.startIndex : folders.index(before: folders.endIndex)
        }

        guard folders.indices.contains(destinationIndex) else { return false }
        selectFolder(folders[destinationIndex])
        return self.selectedFolder?.id == folders[destinationIndex].id
    }

    @discardableResult
    func expandSelectedSidebarFolder() -> Bool {
        guard isSidebarSelectionEnabled,
              let selectedFolder,
              !isFolderExpanded(selectedFolder),
              !hasLoadedChildren(for: selectedFolder) || !children(of: selectedFolder).isEmpty
        else { return false }

        setFolder(selectedFolder, expanded: true)
        return true
    }

    @discardableResult
    func collapseSelectedSidebarFolder() -> Bool {
        guard isSidebarSelectionEnabled,
              let selectedFolder,
              isFolderExpanded(selectedFolder)
        else { return false }

        setFolder(selectedFolder, expanded: false)
        return true
    }

    func folder(for id: BrowserFolderItem.ID) -> BrowserFolderItem? {
        rootFolders.first { $0.id == id } ?? folderChildren.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    func selectFolder(_ folder: BrowserFolderItem) {
        guard isSidebarSelectionEnabled else { return }
        guard startSecurityScopedAccess(for: securityScopedURL(for: folder.url)) else { return }

        let currentScanID = UUID()
        scanID = currentScanID
        selectedFolder = folder
        selectedFileID = nil
        selectedFileIDs = []
        selectionAnchorFileID = nil
        resetZoomInterfaceState()
        clearSemanticSearchResults()
        isCreatingThumbnails = false
        scanTask?.cancel()
        thumbnailTask?.cancel()
        closeZoom()

        scanTask = Task {
            isScanning = true
            async let folders = RawImageLoader.shared.discoverFolders(at: folder.url)
            async let discoveredFiles = RawImageLoader.shared.discoverSupportedFiles(at: folder.url)
            let (loadedFolders, loadedFiles) = await (folders, discoveredFiles)
            guard !Task.isCancelled, currentScanID == scanID else { return }
            setLoadedChildren(loadedFolders, for: folder)
            files = loadedFiles
            selectedFileID = loadedFiles.first?.id
            selectedFileIDs = Set(loadedFiles.first.map { [$0.id] } ?? [])
            selectionAnchorFileID = loadedFiles.first?.id
            isScanning = false
        }
        if let directory = clipCatalogURL {
            useCatalogCLIPIndex(at: directory)
        }
    }

    private func loadChildrenIfNeeded(for folder: BrowserFolderItem) {
        Task {
            await loadChildren(for: [folder])
        }
    }

    private func loadChildren(for folders: [BrowserFolderItem]) async {
        for folder in folders where folderChildren[folder.id] == nil && !loadingFolderIDs.contains(folder.id) {
            guard startSecurityScopedAccess(for: securityScopedURL(for: folder.url)) else { continue }
            loadingFolderIDs.insert(folder.id)
            let loadedFolders = await RawImageLoader.shared.discoverFolders(at: folder.url)
            guard !Task.isCancelled else {
                loadingFolderIDs.remove(folder.id)
                return
            }
            setLoadedChildren(loadedFolders, for: folder)
            loadingFolderIDs.remove(folder.id)
        }
    }

    private func setLoadedChildren(_ children: [BrowserFolderItem], for folder: BrowserFolderItem) {
        folderChildren[folder.id] = children
        if rootFolders.contains(where: { $0.id == folder.id }), !children.isEmpty {
            expandedFolderIDs.insert(folder.id)
        }
    }

    private func setCLIPIndexPresence(_ isPresent: Bool, for directory: URL) {
        let folderID = directory.standardizedFileURL

        func updated(_ folder: BrowserFolderItem) -> BrowserFolderItem {
            BrowserFolderItem(
                url: folder.url,
                supportedFileCount: folder.supportedFileCount,
                hasCLIPIndex: isPresent,
            )
        }

        if let index = rootFolders.firstIndex(where: { $0.url.standardizedFileURL == folderID }) {
            rootFolders[index] = updated(rootFolders[index])
        }

        for parentID in Array(folderChildren.keys) {
            guard var children = folderChildren[parentID],
                  let index = children.firstIndex(where: { $0.url.standardizedFileURL == folderID })
            else { continue }
            children[index] = updated(children[index])
            folderChildren[parentID] = children
        }

        if let selectedFolder, selectedFolder.url.standardizedFileURL == folderID {
            self.selectedFolder = updated(selectedFolder)
        }
    }

    func selectOnlyFile(_ file: BrowserFileItem) {
        selectedFileID = file.id
        selectedFileIDs = [file.id]
        selectionAnchorFileID = file.id
    }

    func toggleFileSelection(_ file: BrowserFileItem) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
            if selectedFileID == file.id {
                selectedFileID = selectedFiles.first?.id
            }
        } else {
            selectedFileIDs.insert(file.id)
            selectedFileID = file.id
            selectionAnchorFileID = file.id
        }

        if selectedFileIDs.isEmpty {
            selectedFileID = nil
            selectionAnchorFileID = nil
        }
    }

    func extendFileSelection(to file: BrowserFileItem) {
        guard let anchorID = selectionAnchorFileID ?? selectedFileID,
              let anchorIndex = displayedFiles.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = displayedFiles.firstIndex(of: file)
        else {
            selectOnlyFile(file)
            return
        }

        let bounds = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
        selectedFileIDs = Set(displayedFiles[bounds].map(\.id))
        selectedFileID = file.id
    }

    func openZoom(
        for file: BrowserFileItem? = nil,
        initialZoomMode: BrowserZoomInitialMode = .fit,
        showFocusPointOnOpen: Bool = false,
        preserveViewport: Bool = false,
    ) {
        if let file {
            selectedFileID = file.id
        }
        guard let selectedFile else { return }

        let shouldLoadSidecar = raw9LoadedSidecarURL != selectedFile.url
        if raw9AdjustmentURL != selectedFile.url {
            isRestoringRAW9Adjustments = true
            raw9Adjustments = RAW9Adjustments()
            isRestoringRAW9Adjustments = false
            raw9AdjustmentURL = selectedFile.url
            raw9SidecarError = nil
        }
        let initialAdjustments = raw9Adjustments
        let pendingSave = raw9SidecarSaveTask
        zoomTask?.cancel()
        if !preserveViewport {
            zoomImage = nil
        }
        zoomImageError = nil
        zoomExifInfo = nil
        isZoomExifInfoLoaded = false
        if !preserveViewport {
            zoomLaunchContext = BrowserZoomLaunchContext(
                initialZoomMode: initialZoomMode,
                showFocusPointOnOpen: showFocusPointOnOpen,
            )
        }
        zoomOverlayVisible = true
        let previewSize = settings.thumbnailSizeFullSize
        zoomTask = Task {
            async let exifInfo = RawImageLoader.shared.metadata(for: selectedFile.url)
            do {
                let supportsRAW9 = await RAW9Support.isSupported(for: selectedFile.url)
                try Task.checkCancellation()
                if shouldLoadSidecar, supportsRAW9 {
                    await pendingSave?.value
                    do {
                        let saved = try await raw9SidecarStore.load(for: selectedFile.url)
                        try Task.checkCancellation()
                        if raw9LoadedSidecarURL != selectedFile.url, raw9Adjustments == initialAdjustments, let saved {
                            isRestoringRAW9Adjustments = true
                            raw9Adjustments = saved
                            isRestoringRAW9Adjustments = false
                        }
                        raw9LoadedSidecarURL = selectedFile.url
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        raw9LoadedSidecarURL = selectedFile.url
                        raw9SidecarError = "Could not read RAW 9 sidecar: \(error.localizedDescription)"
                    }
                }
                try Task.checkCancellation()
                let adjustments = raw9Adjustments
                let developRAW = useDevelopedRAW && !SupportedFileType.isRenderedImage(selectedFile.url)
                let loadedImage: CGImage? = if developRAW {
                    if supportsRAW9 {
                        try await raw9Renderer.render(url: selectedFile.url, adjustments: adjustments, bitDepth: settings.rawPreviewBitDepth)
                    } else {
                        try await RawImageLoader.shared.developedPreview(for: selectedFile.url)
                    }
                } else {
                    await RawImageLoader.shared.previewImage(
                        for: selectedFile.url, maxPixelSize: previewSize,
                    )
                }
                guard !Task.isCancelled else { return }
                zoomImage = loadedImage
                if loadedImage == nil {
                    zoomImageError = "Unable to load this image."
                }
            } catch {
                guard !Task.isCancelled else { return }
                zoomImageError = "RAW development failed: \(error.localizedDescription)"
            }
            let loadedExifInfo = await exifInfo
            guard !Task.isCancelled else { return }
            zoomExifInfo = loadedExifInfo
            isZoomExifInfoLoaded = true
        }
    }

    func raw9ToneSettings() async throws -> RAW9ToneDefaults {
        guard let url = selectedFile?.url else { throw CocoaError(.fileReadUnknown) }
        return try await raw9Renderer.toneSettings(url: url)
    }

    func raw9WhiteBalance(normalizedPoint: CGPoint? = nil) async throws -> (temperature: Double, tint: Double) {
        guard let url = selectedFile?.url else { throw CocoaError(.fileReadUnknown) }
        return try await raw9Renderer.whiteBalance(url: url, normalizedPoint: normalizedPoint)
    }

    /// Refresh only the rendered pixels; retain metadata and viewport state.
    func refreshRAW9Preview() {
        guard zoomOverlayVisible, useDevelopedRAW,
              let url = selectedFile?.url, raw9AdjustmentURL == url else { return }
        let adjustments = raw9Adjustments
        let bitDepth = settings.rawPreviewBitDepth
        zoomTask?.cancel()
        zoomTask = Task {
            do {
                let image = try await raw9Renderer.render(url: url, adjustments: adjustments, bitDepth: bitDepth)
                guard !Task.isCancelled, selectedFile?.url == url, useDevelopedRAW else { return }
                zoomImage = image
                zoomImageError = nil
            } catch {
                guard !Task.isCancelled, selectedFile?.url == url else { return }
                zoomImageError = "RAW development failed: \(error.localizedDescription)"
            }
        }
    }

    func closeZoom() {
        raw9AdjustmentURL = nil
        raw9LoadedSidecarURL = nil
        zoomTask?.cancel()
        zoomTask = nil
        zoomOverlayVisible = false
        zoomImage = nil
        zoomImageError = nil
        zoomExifInfo = nil
        isZoomExifInfoLoaded = false
        zoomLaunchContext = .default
        // Abandon any in-flight full-size decode: it's no longer needed and
        // should not keep consuming memory in the background.
        Task { await RawImageLoader.shared.cancelPreview() }
    }

    func resetZoomInterfaceState() {
        zoomScale = 1.0
        zoomOffset = .zero
        isZoomExifInfoLoaded = false
        isZoomMetadataCollapsed = false
        zoomMetadataOffset = .zero
        isZoomFocusPointVisible = false
        zoomLaunchContext = .default
    }

    func navigateSelection(by delta: Int) {
        guard let selectedFile,
              let currentIndex = displayedFiles.firstIndex(of: selectedFile)
        else { return }

        let nextIndex = currentIndex + delta
        guard displayedFiles.indices.contains(nextIndex) else { return }
        selectedFileID = displayedFiles[nextIndex].id
        selectedFileIDs = [displayedFiles[nextIndex].id]
        selectionAnchorFileID = displayedFiles[nextIndex].id
        if zoomOverlayVisible {
            openZoom(
                for: displayedFiles[nextIndex],
                initialZoomMode: zoomLaunchContext.initialZoomMode,
                showFocusPointOnOpen: zoomLaunchContext.showFocusPointOnOpen,
            )
        }
    }

    func clearRememberedCatalogs() async {
        clearCatalogCLIPIndexes()
        scanTask?.cancel()
        thumbnailTask?.cancel()
        closeZoom()
        stopActiveSecurityScopedAccess()

        rootFolders = []
        folderChildren = [:]
        expandedFolderIDs = []
        loadingFolderIDs = []
        files = []
        selectedFolder = nil
        selectedFileID = nil
        selectedFileIDs = []
        selectionAnchorFileID = nil
        rememberedCatalogs = [:]
        isScanning = false
        isCreatingThumbnails = false
        resetCLIPIndexSelection()
        await RememberedCatalogStore.clear()
    }

    func removeRootCatalog(_ folder: BrowserFolderItem) async {
        let catalogURL = folder.url.standardizedFileURL
        let removedSelectedFolder = selectedFolder?.url.standardizedFileURL.isEqualOrDescendant(of: catalogURL) == true

        scanTask?.cancel()
        thumbnailTask?.cancel()
        if removedSelectedFolder {
            closeZoom()
            files = []
            selectedFolder = nil
            selectedFileID = nil
            selectedFileIDs = []
            selectionAnchorFileID = nil
            isScanning = false
            isCreatingThumbnails = false
            resetCLIPIndexSelection()
        }

        rootFolders.removeAll { $0.url.standardizedFileURL == catalogURL }
        folderChildren = folderChildren.filter { key, _ in
            !key.standardizedFileURL.isEqualOrDescendant(of: catalogURL)
        }
        expandedFolderIDs = expandedFolderIDs.filter {
            !$0.standardizedFileURL.isEqualOrDescendant(of: catalogURL)
        }
        loadingFolderIDs = loadingFolderIDs.filter {
            !$0.standardizedFileURL.isEqualOrDescendant(of: catalogURL)
        }
        catalogIndexValidationTasks.removeValue(forKey: catalogURL)?.cancel()
        catalogCLIPIndexes.removeValue(forKey: catalogURL)
        rememberedCatalogs.removeValue(forKey: catalogURL)
        if activeSecurityScopedURL == catalogURL {
            stopActiveSecurityScopedAccess()
        }

        await saveRememberedCatalogs()
    }

    func stopActiveSecurityScopedAccess() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }

    private func activateSavedQwenModel() {
        guard let url = resolvedQwenModelURL() else {
            qwenValidationTask?.cancel()
            qwenResponseTask?.cancel()
            activeQwenModelURL = nil
            isQwenResponding = false
            Task { await qwenModelManager.clear() }
            qwenModelStatus = .notConfigured
            return
        }
        validateQwenModel(at: url)
    }

    private func resolvedQwenModelURL() -> URL? {
        managedCLIPModelLocations[.qwen3VL2B]
    }

    private func validateQwenModel(at url: URL) {
        let standardizedURL = url.standardizedFileURL
        activeQwenModelURL = standardizedURL
        qwenValidationTask?.cancel()
        qwenResponseTask?.cancel()
        isQwenResponding = false
        qwenFeatureError = nil
        qwenModelStatus = .checking(standardizedURL)

        qwenValidationTask = Task { [weak self] in
            guard let self else { return }
            let status = await qwenModelManager.validate(url: standardizedURL)
            guard !Task.isCancelled, activeQwenModelURL == standardizedURL else { return }
            qwenModelStatus = status
            qwenValidationTask = nil
        }
    }

    private func securityScopedURL(for folderURL: URL) -> URL {
        let standardizedFolderURL = folderURL.standardizedFileURL
        return rootFolders
            .map(\.url)
            .filter { rootURL in
                standardizedFolderURL.isEqualOrDescendant(of: rootURL.standardizedFileURL)
            }
            .max { first, second in
                first.standardizedFileURL.pathComponents.count < second.standardizedFileURL.pathComponents.count
            } ?? folderURL
    }

    private func rememberCatalog(at url: URL) {
        guard let catalog = RememberedCatalogStore.catalog(for: url) else { return }
        rememberedCatalogs[url.standardizedFileURL] = catalog
        Task {
            await saveRememberedCatalogs()
        }
    }

    private func saveRememberedCatalogs() async {
        let catalogs = rootFolders.compactMap { rememberedCatalogs[$0.url.standardizedFileURL] }
        await RememberedCatalogStore.save(catalogs)
    }

    private func uniqueFolders(_ folders: [BrowserFolderItem]) -> [BrowserFolderItem] {
        var seen: Set<URL> = []
        return folders
            .filter { folder in
                guard !seen.contains(folder.url) else { return false }
                seen.insert(folder.url)
                return true
            }
    }

    private func startSecurityScopedAccess(for url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        if activeSecurityScopedURL == standardizedURL {
            return true
        }
        guard standardizedURL.startAccessingSecurityScopedResource() else {
            return false
        }
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = standardizedURL
        return true
    }

    private func activateSelectedCLIPModel() {
        let selectedURL = managedCLIPModelLocations[settings.selectedCLIPModel.downloadID]

        guard let modelURL = selectedURL else {
            deactivateCLIPModelRuntime()
            return
        }

        let standardizedURL = modelURL.standardizedFileURL
        let isCurrentModelReady = activeCLIPModelURL == standardizedURL && clipProvider != nil
        let isCurrentModelBeingValidated = activeCLIPModelURL == standardizedURL
            && modelValidationTask != nil
        guard !isCurrentModelReady && !isCurrentModelBeingValidated else { return }

        validateCLIPModel(at: standardizedURL)
    }

    private func activateSelectedSAM3Model() {
        let selectedURL = managedCLIPModelLocations[.sam3]

        let standardizedURL = selectedURL?.standardizedFileURL
        guard activeSAM3ModelURL != standardizedURL else { return }
        validateSAM3Model(at: standardizedURL)
    }

    private func validateSAM3Model(at url: URL?) {
        let standardizedURL = url?.standardizedFileURL
        activeSAM3ModelURL = standardizedURL
        sam3ValidationTask?.cancel()
        sam3ModelStatus = .checking(expectedLocations: standardizedURL.map { [$0] } ?? [])

        sam3ValidationTask = Task { [weak self] in
            guard let self else { return }
            let status = await deepAIReviewRuntime.activateSAM3(
                at: standardizedURL,
                controller: deepAIReviewController,
            )
            guard !Task.isCancelled, activeSAM3ModelURL == standardizedURL else { return }
            sam3ModelStatus = status
            sam3ValidationTask = nil
        }
    }

    private func performCLIPModelDownload(_ id: CLIPModelDownloadID) async {
        defer { clipModelDownloadTasks[id] = nil }
        do {
            let location = try await clipModelDownloadCoordinator.download(
                id,
                progress: { [weak self] progress in
                    guard let self, !Task.isCancelled else { return }
                    clipModelDownloadStates[id] = .downloading(
                        progress: min(max(progress, 0), 1),
                    )
                },
            )
            try Task.checkCancellation()
            clipModelDownloadStates[id] = .validating
            managedCLIPModelLocations[id] = location
            if id == settings.selectedCLIPModel.downloadID {
                validateCLIPModel(at: location)
            }
            await refreshCLIPModels()
        } catch is CancellationError {
            let snapshot = await clipModelDownloadCoordinator.snapshot()
            clipModelDownloadStates[id] = snapshot.states[id] ?? .ready
        } catch {
            clipModelDownloadStates[id] = .failed(message: String(describing: error))
        }
    }

    private func deactivateCLIPModelRuntime() {
        clearCatalogCLIPIndexes()
        activeCLIPModelURL = nil
        modelValidationTask?.cancel()
        indexingTask?.cancel()
        indexValidationTask?.cancel()
        searchTask?.cancel()
        clipModelStatus = .notConfigured
        clipProvider = nil
        clipEngine = nil
        clipEngineDirectoryURL = nil
        hasCompatibleCLIPIndex = false
        clipIndexStatus = selectedFolder == nil ? .noFolderSelected : .modelRequired
        isIndexing = false
        isSearching = false
        clearSemanticSearchResults()
    }

    private func validateCLIPModel(at url: URL) {
        clearCatalogCLIPIndexes()
        let url = url.standardizedFileURL
        activeCLIPModelURL = url
        modelValidationTask?.cancel()
        indexingTask?.cancel()
        indexValidationTask?.cancel()
        searchTask?.cancel()
        indexingID = UUID()
        indexValidationID = UUID()
        searchID = UUID()
        clipModelStatus = .checking(url)
        clipProvider = nil
        clipEngine = nil
        clipEngineDirectoryURL = nil
        hasCompatibleCLIPIndex = false
        clipIndexStatus = selectedFolder == nil ? .noFolderSelected : .modelRequired
        isIndexing = false
        isSearching = false
        clipFeatureError = nil
        clearSemanticSearchResults()

        modelValidationTask = Task { [weak self] in
            guard let self else { return }
            let load = await self.clipModelManager.load(url: url)
            guard !Task.isCancelled, self.activeCLIPModelURL == url else { return }
            self.clipModelStatus = load.status
            self.clipProvider = load.provider
            for folder in self.rootFolders {
                self.validateCatalogCLIPIndex(at: folder.url.standardizedFileURL)
            }
            if let directory = self.clipCatalogURL {
                self.useCatalogCLIPIndex(at: directory)
            } else if let provider = load.provider,
                      let directoryPath = self.settings.lastIndexedDirectoryPath {
                await self.restoreCLIPEngine(
                    provider: provider,
                    directory: URL(filePath: directoryPath),
                )
            }
            self.modelValidationTask = nil
        }
    }

    private func restoreCLIPEngine(
        provider: CoreAICLIPProvider,
        directory: URL,
    ) async {
        let standardizedDirectory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardizedDirectory.path,
            isDirectory: &isDirectory,
        ), isDirectory.boolValue else { return }
        let engine = makeCLIPEngine(provider: provider, directory: standardizedDirectory)
        guard await engine.hasCompatibleIndex() else { return }
        clipEngine = engine
        clipEngineDirectoryURL = standardizedDirectory
        let status = await engine.validateIndex(directory: standardizedDirectory)
        clipIndexStatus = status
        hasCompatibleCLIPIndex = status.allowsSearch
    }

    private func makeCLIPEngine(
        provider: CoreAICLIPProvider,
        directory: URL,
    ) -> CLIPSearchEngine {
        let indexURL = CLIPIndexPaths.defaultIndexURL(
            directory: directory,
            modelFingerprint: provider.backendDescriptor.modelFingerprint,
        )
        return CLIPSearchEngine(
            provider: provider,
            indexStore: CLIPIndexStore(fileURL: indexURL),
            concurrencyLimit: 1,
        )
    }

    private func publishIndexingProgress(
        _ progress: CLIPIndexingProgress,
        operationID: UUID,
    ) {
        guard indexingID == operationID else { return }
        indexingProgress = progress
    }

    private func resetCLIPIndexSelection() {
        indexingTask?.cancel()
        indexValidationTask?.cancel()
        searchTask?.cancel()
        indexingID = UUID()
        indexValidationID = UUID()
        searchID = UUID()
        clipEngine = nil
        clipEngineDirectoryURL = nil
        clipIndexStatus = .noFolderSelected
        hasCompatibleCLIPIndex = false
        isIndexing = false
        indexingProgress = nil
        clearSemanticSearchResults()
    }

    private func persistSettings() {
        let updatedSettings = settings
        Task {
            await BrowserSettingsStore.save(updatedSettings)
        }
    }
}
