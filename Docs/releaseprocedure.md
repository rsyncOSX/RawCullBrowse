# RawCullBrowse release procedure

Prepared 1 October 2026. This runbook covers developer-account registration, signing, packaging existing converted models with RawCullBrowse's own asset pack IDs, uploads, internal TestFlight, and the first Mac App Store submission. Account actions and uploads have not been performed by creating this document.

## 1. Register the app, downloader, and shared app group

### Identifier inventory

| Item | Exact value | Purpose |
| --- | --- | --- |
| Developer Team ID | `93M47F4H9T` | Team currently configured in the project; confirm this is your selected membership |
| Main app bundle ID | `no.blogspot.RawCullBrowse` | Register an explicit App ID and create the App Store Connect app with this ID |
| Downloader bundle ID | `no.blogspot.RawCullBrowse.ModelDownloader` | Register a separate explicit App ID for the embedded extension |
| Shared app group | `group.no.blogspot.RawCullBrowse.model-assets` | Register once and associate with both App IDs |
| Test bundle ID | `no.blogspot.RawCullBrowseTests` | Local test target; no separate App Store Connect app is needed |
| App Store Connect SKU | `RawCullBrowse-macOS` | Internal app record bookkeeping value |
| Xcode scheme | `RawCullBrowse` | Archive this scheme |
| Archive configuration | `Release` | This project has no separate AppStore configuration |
| Minimum macOS version | `27.0` | Current deployment target; testing requires a compatible Mac |
| App Store Connect numeric Apple ID | `6818066038` | Required to target asset uploads; distinct from your sign-in Apple Account |

The downloader is shipped inside RawCullBrowse. It does not have its own store listing. Model pack identifiers are also separate from bundle IDs and App Groups.

### Register both explicit App IDs

1. Sign in to [Apple Developer Account](https://developer.apple.com/account/) and select the membership matching the team above.
2. Open **Certificates, Identifiers & Profiles → Identifiers → + → App IDs → App**.
3. Register description `RawCullBrowse`, explicit bundle ID `no.blogspot.RawCullBrowse`, with **App Groups** enabled.
4. Repeat with description `RawCullBrowse Model Downloader`, explicit bundle ID `no.blogspot.RawCullBrowse.ModelDownloader`, also enabling **App Groups**.
5. If either ID exists already, inspect and update that record rather than creating an alternative spelling.

Registration requires Account Holder or Admin access. See [Register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id/).

### Register and associate the App Group

1. In **Identifiers**, add an **App Group** with description `RawCullBrowse model assets` and identifier `group.no.blogspot.RawCullBrowse.model-assets`.
2. Edit the main App ID's **App Groups** configuration and select this group; save.
3. Edit the downloader App ID and select the same group; save.
4. Confirm both records belong to the same team.
5. Refresh provisioning for both targets after changing these associations.

This project uses a provisioned `group.` identifier on macOS. Both signed processes need profiles authorizing that exact group. Xcode automatic signing can refresh profiles when **Register App Groups** is enabled. See [Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group/) and [Provisioned app groups on macOS](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

### Verify Xcode signing and downloader requirements

Check the following setup against the repository and the refreshed signing profiles:

| Location | Required setting |
| --- | --- |
| Both targets, Signing & Capabilities | Same team, automatic signing, App Sandbox, shared App Group |
| App target, Build Settings | `REGISTER_APP_GROUPS = YES` is already explicit |
| Downloader target, Build Settings | Verify `REGISTER_APP_GROUPS = YES` resolves; the project does not currently set it explicitly for this target. Set it to Yes if automatic provisioning does not register/authorize the group |
| Both entitlement files | `com.apple.security.application-groups` contains the shared group; `com.apple.security.app-sandbox = true` |
| App Info.plist | `BAAppGroupID = group.no.blogspot.RawCullBrowse.model-assets` |
| App Info.plist | `BAHasManagedAssetPacks = true`; `BAUsesAppleHosting = true` |
| Extension Info.plist | `EXAppExtensionAttributes.EXExtensionPointIdentifier = com.apple.background-asset-downloader-extension` |
| Extension implementation | `@main struct RawCullBrowseModelDownloader: StoreDownloaderExtension {}` using StoreKit |
| Extension Release settings | `SKIP_INSTALL = YES`; extension embedded in the main app |

Apple's managed Apple-hosted setup requires the shared group, downloader extension, and these three app plist keys. Omit other Background Assets plist keys for this hosting mode; there is no custom manifest-server URL to enter. This project already has the extension, so do not add a second one. See [Downloading Apple-hosted asset packs](https://developer.apple.com/documentation/backgroundassets/downloading-apple-hosted-asset-packs).

Open each target's **Signing & Capabilities** tab and resolve signing errors. If using manual signing, create separate **Mac App Store Connect** profiles for the two explicit App IDs after the group associations are saved. Use App Store distribution signing rather than Developer ID signing. See [Create an App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile).

## 2. Create RawCullBrowse in App Store Connect

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com/).
2. In **Apps**, select **+ → New App**.
3. Choose macOS, name `RawCullBrowse` if available, the intended primary language, and bundle ID `no.blogspot.RawCullBrowse`.
4. Use the registered internal SKU `RawCullBrowse-macOS`. The SKU is an account bookkeeping value, not a bundle ID.
5. Set access for your intended team members and create the record.
6. Open **App Information** and confirm its numeric **Apple ID** is `6818066038`. Do not use RawCull's numeric ID `6759362764` for RawCullBrowse uploads.

```text
RawCullBrowse numeric Apple ID: 6818066038
RawCullBrowse SKU:              RawCullBrowse-macOS
Selected developer team:       ____________________
Registration/signing checked:  ____________________
```

See [Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).

## 3. Create packages with RawCullBrowse's own IDs

Use the existing converted model files to create new `.aar` packages with the IDs already configured in RawCullBrowse's catalog. No model conversion or catalog ID change is needed.

| Model | RawCullBrowse pack ID | Model path inside pack |
| --- | --- | --- |
| DataComp CLIP | `rawcullbrowse-clip-datacomp` | `Models/CLIP-DataComp` |
| SAM 3 | `rawcullbrowse-sam3` | `Models/SAM3` |
| Qwen | `rawcullbrowse-qwen3-vl-2b` | `Models/Qwen/qwen3_vl_2b` |

### Prepare separate packaging manifests

The existing model staging root is `/Users/thomas/ModelAssets/Release`. Create separate manifest and output directories there so the original RawCull packaging remains intact:

```sh
cd /Users/thomas/ModelAssets/Release
mkdir -p Packaging/RawCullBrowse Output/RawCullBrowse

python3 - <<'PYTHON'
import json
from pathlib import Path

packs = {
    "clip-datacomp": "rawcullbrowse-clip-datacomp",
    "sam3": "rawcullbrowse-sam3",
    "qwen3-vl-2b": "rawcullbrowse-qwen3-vl-2b",
}
for filename, pack_id in packs.items():
    original = Path("Packaging") / f"{filename}.json"
    manifest = json.loads(original.read_text())
    manifest["assetPackID"] = pack_id
    destination = Path("Packaging/RawCullBrowse") / original.name
    destination.write_text(json.dumps(manifest, indent=2) + "\n")
    print(destination, pack_id)
PYTHON
```

Inspect each new manifest. Preserve `platforms: ["macOS"]`, `downloadPolicy: {"onDemand": {}}`, and the existing model, tokenizer, notice, and licence selectors. Verify included provenance clearly describes the original model evidence; keep new RawCullBrowse upload evidence outside the package. Do not put an archive's own checksum inside that archive.

### Evaluate and package

Run these commands from `/Users/thomas/ModelAssets/Release`; relative selectors resolve against the current working directory, not the manifest directory:

```sh
xcrun ba-package evaluate Packaging/RawCullBrowse/clip-datacomp.json
xcrun ba-package evaluate Packaging/RawCullBrowse/sam3.json
xcrun ba-package evaluate Packaging/RawCullBrowse/qwen3-vl-2b.json
```

Check that the selected files contain the expected models, tokenizers, and notices, with no unintended files. Then package using a release version of Xcode's tool:

```sh
xcrun ba-package package Packaging/RawCullBrowse/clip-datacomp.json \
  --output-path Output/RawCullBrowse/clip-datacomp.aar --verbose
xcrun ba-package package Packaging/RawCullBrowse/sam3.json \
  --output-path Output/RawCullBrowse/sam3.aar --verbose
xcrun ba-package package Packaging/RawCullBrowse/qwen3-vl-2b.json \
  --output-path Output/RawCullBrowse/qwen3-vl-2b.aar --verbose
```

The model files retain their checksums because their bytes are unchanged. The new packaged identifiers change archive content, so measure new `.aar` hashes and sizes. Changing packaged notices or provenance also changes archive bytes.

## 4. Measure and record the new archives

Upload only the new outputs:

```text
/Users/thomas/ModelAssets/Release/Output/RawCullBrowse/clip-datacomp.aar
/Users/thomas/ModelAssets/Release/Output/RawCullBrowse/sam3.aar
/Users/thomas/ModelAssets/Release/Output/RawCullBrowse/qwen3-vl-2b.aar
```

Measure them after packaging:

```sh
stat -f '%N|%z' /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/clip-datacomp.aar \
  /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/sam3.aar \
  /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/qwen3-vl-2b.aar

shasum -a 256 /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/clip-datacomp.aar \
  /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/sam3.aar \
  /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/qwen3-vl-2b.aar
```

| New archive | Measured bytes | Measured SHA-256 |
| --- | --- | --- |
| `clip-datacomp.aar` | Record after packaging | Record after packaging |
| `sam3.aar` | Record after packaging | Record after packaging |
| `qwen3-vl-2b.aar` | Record after packaging | Record after packaging |

These packages have not been created by writing this runbook. Record their measured values before uploading, and check again against that record before each delivery. Update archive hash/size metadata displayed by the app where applicable to describe the new packages; retain the established model-file checksums.

The repository's `ModelAssets/Notices/*/PROVENANCE.json` records describe RawCull's original releases. Keep those historical records distinguishable from new RawCullBrowse upload evidence. Do not copy RawCull's pack-record IDs, version-record IDs, or approval states into a RawCullBrowse release record.

## 5. Upload the asset packs

### Recommended explicit targeting: altool

Apple documents `altool` asset upload with an archive path, the app's numeric Apple ID, and account credentials. Use an account with Account Holder, Admin, App Manager, or Developer access. See [Upload Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/manage-asset-packs/upload-apple-hosted-asset-packs).

1. Confirm the active Xcode installation using `xcode-select -p` and `xcodebuild -version`.
2. Run `xcrun altool --help` and confirm it works before starting a multi-gigabyte upload. During preparation of this runbook, the local invocation failed because `Defaults.properties` was missing; the command-line upload route needs that tooling issue resolved first. Transporter is the alternative below.
3. Authenticate using an app-specific password stored in Keychain. Use the credential-storage syntax supported by your installed `altool`; the examples below assume the Keychain item is named `RawCullBrowseASC`. Keep the password out of this document and shell history.
4. The commands below use **RawCullBrowse's numeric Apple ID `6818066038`**. Replace the email placeholder with your sign-in email.
5. Upload CLIP first:

```sh
xcrun altool \
  --upload-asset-pack /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/clip-datacomp.aar \
  --apple-id '6818066038' \
  -u '<APP_STORE_CONNECT_EMAIL>' \
  -p '@keychain:RawCullBrowseASC'
```

6. Wait for successful processing and verify the destination app and pack identifier in section 6.
7. Upload SAM 3:

```sh
xcrun altool \
  --upload-asset-pack /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/sam3.aar \
  --apple-id '6818066038' \
  -u '<APP_STORE_CONNECT_EMAIL>' \
  -p '@keychain:RawCullBrowseASC'
```

8. Upload Qwen:

```sh
xcrun altool \
  --upload-asset-pack /Users/thomas/ModelAssets/Release/Output/RawCullBrowse/qwen3-vl-2b.aar \
  --apple-id '6818066038' \
  -u '<APP_STORE_CONNECT_EMAIL>' \
  -p '@keychain:RawCullBrowseASC'
```

9. Save delivery logs and upload dates. A completed transfer is not the same as completed Apple processing.

Apple assigns pack versions automatically; do not assume RawCullBrowse's versions match RawCull's.

### Transporter alternative

Open Apple's **Transporter** app, sign in, and select the correct provider/team. Add CLIP first and follow the asset delivery prompts. Confirm the destination is RawCullBrowse before delivery; the archive must be delivered to the correct app record. If the UI does not let you establish the correct destination, use the explicitly targeted command-line upload or Apple's API rather than guessing. After CLIP succeeds, repeat for SAM 3 and Qwen and save delivery logs.

Apple also supports the [Background Assets API](https://developer.apple.com/documentation/appstoreconnectapi/managing-apple-hosted-background-assets) for automated uploads; it is an alternative to these manual steps.

## 6. Verify processing and record release evidence

In **Apps → RawCullBrowse → TestFlight → Builds & Assets → Asset Packs**, inspect each uploaded pack. The Asset Packs section appears after uploads. Internal testing automatically uses the latest processed version. See [Test Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/test-a-beta-version/test-apple-hosted-asset-packs/).

For each pack, confirm the app, exact RawCullBrowse ID listed in section 3, macOS platform, version, successful processing, and readiness for internal testing. Inspect any validation failure before uploading another copy.

Record outside the archive:

| Evidence | CLIP | SAM 3 | Qwen |
| --- | --- | --- | --- |
| RawCullBrowse pack ID | | | |
| Archive SHA-256 and bytes | | | |
| Upload date and delivery log | | | |
| RawCullBrowse pack record ID | | | |
| Version and version record ID | | | |
| Processing result/date | | | |
| Internal testing result | | | |
| App Store review result | | | |

## 7. Archive and upload the app

1. Confirm the new packages use the catalog IDs listed in section 3 and record their measured hashes and sizes before building.
2. Select scheme **RawCullBrowse**, destination **My Mac**, and **Edit Scheme → Archive → Release**.
3. Confirm app and extension version/build values agree. Increment the build number for each new app upload.
4. Use **Product → Archive**.
5. In Organizer, confirm the archive contains `RawCullBrowse.app` and its embedded `RawCullBrowseModelDownloader.appex` in the ExtensionKit extensions folder resolved by `$(EXTENSIONS_FOLDER_PATH)` (normally `Contents/Extensions` for this extension type).
6. Use **Validate App** and resolve signing/entitlement failures for both bundles.
7. Select **Distribute App → App Store Connect → Upload**. Do not select **TestFlight Internal Only** if this build will later be submitted for public release. See [Apple's TestFlight tutorial](https://developer.apple.com/tutorials/develop-in-swift/test-your-beta-app).
8. Wait for build processing and complete any export-compliance questions accurately.

The repository also provides `make archive-app-store` to archive and export with `exportOptionsAppStore.plist`; export alone is not upload. Use the current App Store workflow rather than `make build`, which retains older Developer ID/DMG targets.

No model `.aar` files should be embedded in the app archive. The downloader extension and bundled licence text belong there; the model archives are delivered separately.

## 8. Internal TestFlight test procedure

1. In RawCullBrowse's TestFlight tab, create an internal group and add eligible App Store Connect users, including yourself.
2. Add the processed build, complete the required test information, and install it using TestFlight on a compatible Mac.
3. Confirm all three packs are processed under RawCullBrowse.
4. Clear **Manual AI** folder overrides so tests use managed Apple assets.
5. Start with a model not already installed through RawCullBrowse. Record the build number and actual pack versions tested.

Test and record these cases:

- [ ] App launches and browses supported photos before downloading any model.
- [ ] CLIP download reports progress, finishes, and enables semantic search/similarity.
- [ ] SAM 3 licence acceptance works before its download; installed model performs masking.
- [ ] Qwen downloads and produces a photo assessment.
- [ ] Cancellation and retry behave correctly where supported by the UI.
- [ ] Interrupted networking produces a useful state and recovery works.
- [ ] Downloaded models remain usable after quitting and relaunching.
- [ ] Already installed models work offline.
- [ ] Removal and re-download work for each model.
- [ ] Local folder overrides work; clearing them restores managed model use.
- [ ] Missing model files and unavailable packs produce useful messages.
- [ ] No App Group access, downloader launch, or permission errors appear in Console.

Internal tests use the latest processed pack versions. A later upload can therefore change the models being tested without a new app build. External testing is optional and has a separate asset-review flow: submit the external app build first, then select the needed asset versions for external testing. See [Test Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/test-a-beta-version/test-apple-hosted-asset-packs/).

## 9. First App Store submission

Complete the store listing, screenshots, description, support/privacy URLs, privacy answers, age rating, pricing/availability, export compliance, and review contact details. Choose the tested app build. In review notes, explain where AI Models settings are, the on-demand downloads, approximate sizes, SAM licence acceptance, and the steps to exercise each AI feature.

For the first release, add the app version and all three required asset pack versions to the **same submission**:

1. Open RawCullBrowse's **Distribution → General → Asset Packs**.
2. For each pack, choose **Select Asset Pack Version**, select the tested version, and **Add for Review** to the app's draft submission.
3. Confirm the draft contains the macOS app version plus CLIP, SAM 3, and Qwen.
4. Submit for review and monitor both the app and asset outcomes.

Apple requires first-app asset submissions to accompany the first app version. Archives made with beta packaging tools cannot be added for review. Once approved, a new asset version replaces the previous version for App Store users. See [Submit Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-apple-hosted-asset-packs).

Select manual app release if you want a final launch checkpoint. After release, install the public App Store build and repeat at least the three download-and-inference tests; TestFlight success alone does not verify production asset availability.

## 10. Troubleshooting and future releases

| Symptom | Check/action |
| --- | --- |
| Asset unavailable / ID absent | Compare catalog ID with uploaded ID; confirm correct app, platform, processing, and distribution channel |
| Upload appears under RawCull | Verify numeric Apple ID and delivery destination; RawCull and RawCullBrowse have separate records |
| Shared container inaccessible | Confirm group association and matching entitlements/profiles for both app and extension |
| Downloader never runs | Confirm embedded extension, extension point, signing, and the three app plist keys |
| Works with local override only | Clear override; inspect managed download status and packaged model paths |
| `.aar` checksum differs | Identify changed archive bytes; do not claim the historical hash describes a new package |
| Internal testing changes unexpectedly | Check whether someone uploaded a newer processed pack version |
| Cannot submit asset for review | Check packaging tool was a release version and required submission metadata is complete |
| `altool` cannot start | Repair/select the intended Xcode tooling or use Transporter/API; local help currently reports missing `Defaults.properties` |

Preserve delivered archives and release evidence. For model updates, upload a new version under the established pack ID and test it before review. Recheck compatibility with already released app builds before promoting assets. Do not archive a pack as a routine rollback: Apple says this removes all versions, is irreversible, and prevents reuse of the ID. See [Asset-pack lifecycle](https://developer.apple.com/help/app-store-connect/test-a-beta-version/test-apple-hosted-asset-packs/).
