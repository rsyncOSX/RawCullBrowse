# RawCullBrowse Apple-hosted AI assets

The application and downloader extension use Apple-hosted Managed Background Assets for Debug and Release. The app uses the original model metadata, pinned revisions, download sizes, archive hashes, and verified licence text copied from RawCull. Historical PROVENANCE.json files describe the original app's archives and Apple processing; they are reference evidence, not proof of an upload or approval for RawCullBrowse.

Upload packs to RawCullBrowse's App Store Connect record using these exact identifiers and paths:

| Model | Pack identifier | Model path |
| --- | --- | --- |
| DataComp CLIP | `rawcullbrowse-clip-datacomp` | `Models/CLIP-DataComp` |
| SAM 3 | `rawcullbrowse-sam3` | `Models/SAM3` |
| Qwen | `rawcullbrowse-qwen3-vl-2b` | `Models/Qwen/qwen3_vl_2b` |

All three packs were repackaged and uploaded successfully to RawCullBrowse (Apple ID `6818066038`). Each `altool` receipt reports version **1**, with zero errors, warnings, or info messages. The pack UUIDs, version UUIDs, and upload file UUIDs are recorded in the [release procedure](../Docs/releaseprocedure.md#completed-upload-receipts). App Store Connect processing and approval remain to be verified.

For future releases, repackage the original converted models with the matching notices and established pack identifiers. Record new archive hashes, sizes and Apple processing evidence after packaging. The copied archive hashes describe the original archives and will change if packaging changes. No model binaries are checked in.

Register `group.no.blogspot.RawCullBrowse.model-assets` for both bundle identifiers and regenerate signing profiles. Validate managed downloads through Apple's local Background Assets testing tools or TestFlight after uploads finish. Xcode unit-test hosts disable the live service and use injected fakes.

Settings keeps Apple downloads in AI Models and local security-scoped folder overrides in Manual AI for testing. Clearing an override restores the managed model. SAM 3 requires acceptance of the verified bundled licence before downloading.

Archive the Release configuration and export using `exportOptionsAppStore.plist`. App Store Connect processing and App Review remain external release steps.
