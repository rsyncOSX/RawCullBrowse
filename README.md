# RawCullBrowse

RawCullBrowse is a macOS SwiftUI photo browser with local CLIP indexing, semantic search, and local Qwen prompts. It browses and previews JPEG, PNG, HEIC/HEIF, TIFF, Sony ARW, and DNG files, and provides recursive semantic search over supported image formats.

## Requirements

- macOS 27 or later
- **Apple Silicon** (M-series) only
- Xcode 27 and Swift 6 to build from source
- AI features require the corresponding downloaded model or a compatible local Core AI bundle; folder browsing does not require AI models.

## Features

- Add local folders through the macOS folder picker.
- Browse nested folders in a sidebar.
- Generate in-memory thumbnails for supported RAW files, including Sony ARW and DNG, as well as JPEG, TIFF, and PNG files.
- Open a zoom overlay with keyboard navigation, pan, and magnification controls.
- Copy selected original files with **Edit > Copy** or **⌘C**, then paste them into a Finder folder with **⌘V**. Grid view copies all selected files; zoom view copies the displayed file.
- Display available EXIF details such as camera, lens, exposure, ISO, dimensions, and focus point.
- Prefer matching `.jpg` sidecars for RAW full preview images when present.
- Download DataComp CLIP or select and verify a compatible local CLIP/Core AI bundle before enabling indexing or search.
- Download Meta SAM 3 or select and verify a compatible local SAM 3/Core AI bundle for Deep Review.
- Select an indexed image and use **Find Similar** to rank its nearest visual neighbors.
- Recursively and incrementally index a selected folder into its hidden `.clipbench` directory.
- Search locally with natural-language descriptions and show thumbnail/path results.
- Adjust the semantic result limit in steps of ten (default 50, range 10–500).
- Download Qwen3-VL-2B-Instruct or validate a user-selected Qwen vision-language Core AI bundle and analyze one or more selected photos locally with structured, comparable results.
- Enrich SAM 3 Deep Review with CLIP subject labels, EXIF autofocus points, and a whole-frame sharpness score.
- Choose Automatic, Fast, or Full scope when running SAM 3 Deep Review over a selection.

## AI models and settings

Open **RawCullBrowse > Settings > AI Models** to check model availability and open **Download AI Models**. The app uses Apple-hosted Managed Background Assets. macOS downloads, stores, and manages the packs; installed models run locally. Downloaded model locations can change between launches.

| Model | Model path in its asset pack | Purpose |
|---|---|---|
| DataComp CLIP | `Models/CLIP-DataComp` | LAION/OpenCLIP ViT-B/32 256 px embeddings for indexing, semantic search, and Find Similar. |
| Meta SAM 3 | `Models/SAM3` | Subject segmentation for Deep Review. |
| Qwen3-VL-2B-Instruct | `Models/Qwen/qwen3_vl_2b` | Local vision-language prompts and photo assessments. |

The download catalog uses the original project's model versions, pinned upstream revisions, and licence metadata. SAM 3 requires acceptance of the verified bundled SAM licence before downloading. The download sheet provides model cards, licence links, progress, cancellation, removal, and retry controls.

**Manual AI** is a separate settings tab for testing local model bundles. Use **Select CLIP Model**, **Select SAM 3 Model**, or **Select Qwen Model** to choose a folder. A local selection overrides that model's managed download. Clearing the selection restores the downloaded model when available. Compatible local CLIP and SigLIP bundles are supported. The semantic search result limit is also available in this tab.

**CLIP Indexes** manages catalog indexes; **Memory** and **Cache** configure image memory and disk caching.

## CLIP workflow

1. Open **RawCullBrowse > Settings > AI Models**.
2. Download DataComp CLIP, or open **Manual AI** and choose **Select CLIP Model** to use a compatible local Core AI bundle. A manually selected bundle overrides the downloaded model until the selection is cleared.
3. Wait for the model to report a valid verification status.
4. Select the folder that should become the recursive index root.
5. Choose **Index Selected Folder** in the main toolbar. Indexing never starts automatically.
6. Enter a description in the semantic search field and press Return or Search.
7. Double-click a result to inspect its full embedded/rendered JPEG with EXIF information and histogram.

RawCullBrowse stores one model-specific index at `.clipbench/clip-<model-hash>.clipindex` inside the selected root. Source photographs are not modified. Model inference, embeddings, and search stay on the Mac.

## Privacy Policy

Effective date: October 1, 2026.

RawCullBrowse processes your photographs on your Mac. The app does not collect or transmit your photographs, image metadata, search queries, prompts, embeddings, or AI assessments to the developer. It does not include advertising, tracking, or analytics services, and does not require an account.

### Local access and storage

The app accesses folders and files you select through macOS permissions. It reads photographs and their metadata to provide previews, search, and local AI analysis. CLIP, SAM 3, and Qwen model inference runs locally; photographs and prompts are not uploaded for AI processing.

App settings, remembered folder access, image caches, and downloaded models are stored locally. Semantic indexes are stored in the hidden `.clipbench` directory inside the folder you index and may contain image paths and embeddings. If you run Semantic Test, its report is saved in that folder and includes queries and result paths. These files remain until you remove them or use the applicable cleanup controls.

You can clear image caches in **Settings > Cache**, remove managed models through **Download AI Models**, and delete `.clipbench` directories and semantic test reports in Finder. Removing the app does not automatically remove indexes or reports from your photo folders. You control any copying, backup, or synchronization of those folders through other software.

### Downloads and external links

Optional AI model packs are downloaded through Apple's Managed Background Assets service. Apple handles those network requests under its own [Privacy Policy](https://www.apple.com/legal/privacy/). Model downloads do not require uploading your photographs or prompts.

If you open an external model card, licence, or other website link, your browser connects to that website, whose privacy policy applies.

### Contact and changes

For privacy questions, contact the developer through the [RawCullBrowse issue tracker](https://github.com/rsyncOSX/RawCullBrowse/issues). Issues are public; do not include private photographs or other sensitive information. Any information you choose to submit there is handled by GitHub under its [Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement).

This policy will be updated if the app's privacy practices change, with the effective date revised above.

## Swift package dependencies

Requirements are pinned to exact versions or revisions in the Xcode project and recorded in `RawCullBrowse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Revision-pinned dependencies are shown with their complete commit.

| Package (resolved identity) | Resolved pin | Responsibility | Main APIs/products used by RawCullBrowse |
|---|---:|---|---|
| [PhotoAIKit](https://github.com/rsyncOSX/PhotoAIKit) (`photoaikit`) | revision `77cc1d84a5d98a485caa15be102c8a55eb3d7698` | Core AI model discovery and validation, Qwen vision-language loading, CLIP inference, embedding artifacts, multi-object SAM 3 masks, and AI workflow contracts | `CoreAIQwenProvider`, `CoreAICLIPProvider`, `CoreAISAM3Provider`, `PhotoAIContracts`, `PhotoAIWorkflows` |
| [RawParserKit](https://github.com/rsyncOSX/RawParserKit) (`rawparserkit`) | `1.3.1` | RAW metadata, embedded previews, thumbnails, focus-point metadata, and supported-format handling, including Sony ARW and DNG | `RawImageLoader`, `BrowserExifInfo`, `RawFocusPoint` |
| [RawCullCore](https://github.com/rsyncOSX/RawCullCore) (`rawcullcore`) | `1.1.2` | Shared image-analysis utilities | `HistogramCalculator.normalizedLuminanceHistogram` |

The Xcode target also links PhotoAIKit's `CoreAIEfficientSAMBackend`, `CoreAISAM3Backend`, `PhotoAIStorage`, and `VisionFeaturePrintBackend` products. Deep Review uses the SAM 3 backend's composited semantic mask, which includes every object matching the selected prompt.

Resolved transitive dependencies are recorded here as build inputs even though RawCullBrowse does not import their products directly:

| Resolved identity | Resolved pin | Role in the package graph |
|---|---:|---|
| `coreai-models` | revision `475c585fdb0fe82a83c8f777f259e9414bd44c98` | Apple Core AI model and conversion support reached through PhotoAIKit |
| `eventsource` | `1.5.1` | Server-sent-event transport used by transitive model tooling |
| `swift-asn1` | `1.7.2` | ASN.1 support reached through the cryptography stack |
| `swift-collections` | `1.6.0` | Collection data structures used by transitive packages |
| `swift-crypto` | `4.5.2` | Cryptographic primitives used by transitive packages |
| `swift-huggingface` | `0.10.1` | Hugging Face model download and metadata support used by model tooling |
| `swift-jinja` | `2.5.1` | Prompt-template rendering used by model tooling |
| `swift-transformers` | `1.3.4` | Tokenizer and transformer support used by the AI package graph |
| `xgrammar` | `0.2.2` | Grammar-constrained generation support used by Core AI language models |
| `yyjson` | `0.12.0` | C JSON engine used by transitive model tooling |

## Development

Open the project in Xcode:

```sh
open RawCullBrowse.xcodeproj
```

Build from the command line:

```sh
xcodebuild -project RawCullBrowse.xcodeproj -scheme RawCullBrowse -destination 'platform=macOS' build
```

Create a Release archive and a signed app for local testing:

```sh
make archive
open build/RawCullBrowse.app
```

The archive is written to `build/RawCullBrowse.xcarchive`. Its development-signed app is copied to `build/RawCullBrowse.app`; this target does not export an App Store installer or notarize the app.

Create a local debug archive:

```sh
make debug
```

Run the test suite:

```sh
make test-full
```

### App Store release

Build, sign, and upload in one command:

```sh
./Scripts/release.sh internal   # Internal TestFlight testing only
./Scripts/release.sh appstore   # TestFlight and eligible for App Store submission
```

The Makefile equivalents are `make upload-internal` and `make upload-app-store`.
Sign in to your developer account in **Xcode Settings > Accounts** first.
Both commands use the `Release` configuration, automatic signing, and pinned
package versions. Archives and export diagnostics are preserved in `build/releases/`.
They upload the build without submitting it for App Review or publishing it.

Add `--dry-run` to preview either command. Xcode manages upload build numbers by
default. To choose an unused build number explicitly for the app and extension,
use `BUILD_NUMBER=13 ./Scripts/release.sh appstore`.
For API authentication, set `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`;
keep the `.p8` key outside the repository.

After Apple processes the build, assign it to an internal TestFlight group if
automatic distribution is not enabled. An `internal` upload cannot be used for
external TestFlight or App Store submission; choose `appstore` to submit the same
tested build later.


Create a Release archive and export it for App Store Connect:

```sh
make archive-app-store
```

The archive is written to `build/RawCullBrowse-AppStore.xcarchive` and the export to `build/AppStore`. Both Debug and Release use Apple hosting. `exportOptionsAppStore.plist` and the default `exportOptions.plist` use the `app-store-connect` export method.

Before testing managed downloads or submitting a release, configure the app and extension signing profiles with `group.no.blogspot.RawCullBrowse.model-assets`, and upload the three model packs to RawCullBrowse's App Store Connect record using the identifiers in [ModelAssets/README.md](ModelAssets/README.md). Validate live downloads with Apple's local Background Assets testing tools or TestFlight after pack processing completes. Local folder overrides remain available in **Manual AI** for development. Unit tests disable the live download service and inject test services.

The copied provenance records describe the original project's archives and processing history. RawCullBrowse needs its own packaging, upload, and release evidence. No model binaries are included in this repository.

The Makefile also retains the earlier Developer ID notarization and DMG targets. `make build` still invokes those targets and requires Developer ID signatures, which the local `make archive` target does not provide; use `make archive-app-store` for this project's release workflow.

## Project Layout

- `RawCullBrowse/` — SwiftUI app source and bundled verified licence texts in `Resources/`.
- `RawCullBrowseModelDownloader/` — StoreKit downloader extension for Apple-hosted model packs.
- `RawCullBrowseTests/` — Browser, AI feature, download catalog, and licence acceptance tests.
- `RawCullBrowse.xcodeproj/` — Xcode project, schemes, and Swift package resolution files.
- `RawCullBrowse-Info.plist` — Managed Background Assets and app metadata.
- `RawCullBrowse.entitlements` — App sandbox, user-selected file access, and shared model asset group.
- `RawCullBrowseicon.icon/` — Icon Composer app icon bundle.
- `Assets.xcassets/` — Shared asset catalog.
- `ModelAssets/` — Pack manifest template, notices, historical provenance, and release setup instructions.
- `Makefile` — Build, test, archive, and export automation.
- `exportOptionsAppStore.plist` and `exportOptions.plist` — App Store Connect archive export settings.
- `exportOptionsDebug.plist` — Local debug archive export settings.
