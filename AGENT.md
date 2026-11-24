# AGENT.md — Head3DCapture iOS Project & GitHub Actions Build Guide

## 1. Project Overview
`Head3DCapture` is a minimalist iOS SwiftUI + AVFoundation + Metal data collection application for the **Head3D** project.
It captures:
- Front **TrueDepth** camera RGB image (`rgb.jpg`)
- Uncompressed 32-bit float depth map (`depth.tiff`, unit: meters, `Float32` / `CV_32FC1` compatible)
- Scaled camera intrinsics & metadata (`intrinsics.json`)
- Real-time 3D point cloud visualization rendered via **Metal (`MTKView`)** with pan/pinch/double-tap gestures.

Saved captures are written to the app's `Documents/Head3D_<timestamp>/` folder and exposed via iOS File Sharing (`UIFileSharingEnabled` and `LSSupportsOpeningInPlace`).

---

## 2. Repository Structure
```text
Head3DCapture/
├── AGENT.md
├── Info.plist
├── .gitignore
├── .github/
│   └── workflows/
│       └── build-ipa.yml
├── scripts/
│   ├── fetch-ipa.mjs        # 触发/等待 CI 并把 Head3DCapture.ipa 下载到 ./artifacts/
│   └── make-appicon.ps1     # 由 docs/logo.jpg 生成 AppIcon 全尺寸 PNG（Windows / System.Drawing）
├── docs/
│   └── logo.jpg             # 封面图源文件（原始素材，勿删）
└── Sources/
    ├── Head3DCaptureApp.swift
    ├── TrueDepthCaptureManager.swift
    ├── PointCloudMetalView.swift
    └── Assets.xcassets/
        └── AppIcon.appiconset/   # 由 scripts/make-appicon.ps1 生成，已入库
```

---

## 3. Instructions for Local AI Coding Agent
When asked to modify, inspect, or prepare this project for GitHub Actions compilation:
1. **Keep dependencies minimal**: Do not introduce CocoaPods, Carthage, or heavy third-party frameworks unless explicitly requested. Rely on native Apple frameworks (`AVFoundation`, `CoreImage`, `Metal`, `MetalKit`, `simd`, `SwiftUI`, `UIKit`).
2. **Preserve core data contracts**:
   - Keep `depth.tiff` encoded as 32-bit float (`format: .Lf`, `CGColorSpace.linearGray`) so desktop/C++/Python pipelines can load `CV_32FC1` meters without lossy quantization.
   - Keep `intrinsics.json` scaled to `depth_width` x `depth_height` (`fx, fy, cx, cy`).
   - Keep `isDepthDataFiltered = false` and `depthDataOutput.isFilteringEnabled = false` unless explicitly asked to enable smoothing, so raw structured-light depth behavior is preserved.
   - Keep `UIFileSharingEnabled = true` and `LSSupportsOpeningInPlace = true` in `Info.plist`.
3. **GitHub Actions CI/CD**:
   - The workflow `.github/workflows/build-ipa.yml` runs on `macos-15`, uses `xcodegen` to generate `Head3DCapture.xcodeproj` from an inline `project.yml`, builds an unsigned `.app` (`CODE_SIGN_IDENTITY=""`, `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGNING_ALLOWED=NO`), packages it into `Head3DCapture.ipa` inside `Payload/`, and uploads `Head3DCapture-IPA` as a build artifact.
   - **Never declare an `info:` block in `project.yml`** — xcodegen would overwrite the hand-written `Info.plist` and drop `NSCameraUsageDescription` / `UIFileSharingEnabled` (camera permission crash). The workflow only sets `INFOPLIST_FILE: Info.plist` and `GENERATE_INFOPLIST_FILE: NO`, then asserts the keys with `PlistBuddy` before zipping.
   - **App icon**: `Sources/Assets.xcassets/AppIcon.appiconset` is committed, `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, and `Info.plist` carries `CFBundleIconName`. If `docs/logo.jpg` changes, regenerate with `powershell -NoProfile -File scripts/make-appicon.ps1` (must stay square + **opaque** PNG; actool rejects alpha). The workflow asserts `Assets.car` and `CFBundleIconName` exist before packaging.
   - If adding new `.swift` files under `Sources/`, `xcodegen` automatically picks them up because `sources: - path: Sources` is configured.
   - If adding new Apple system frameworks, add `- sdk: <Framework>.framework` under `targets.Head3DCapture.dependencies` in `.github/workflows/build-ipa.yml`.

---

## 4. Pushing to GitHub & Triggering Build
1. Extract the archive into your target directory/repository.
2. Commit and push to `main` or `master`:
   ```bash
   git add .
   git commit -m "Add Head3DCapture iOS app and IPA build workflow"
   git push origin master
   ```
3. **Credential requirement:** pushing a file under `.github/workflows/` needs a classic PAT with the `workflow` scope. Add it at <https://github.com/settings/tokens> (the token string stays the same, so the stored git credential keeps working). Without it the push fails with:
   `refusing to allow a Personal Access Token to create or update workflow ... without workflow scope`.
   SSH-key auth is not subject to that restriction.
4. Get the IPA locally (triggers a run if needed, waits, downloads, unzips):
   ```bash
   node scripts/fetch-ipa.mjs            # latest run → ./artifacts/Head3DCapture-r<N>.ipa
   node scripts/fetch-ipa.mjs --dispatch # force a fresh workflow_dispatch run first
   ```
   The token comes from `GITHUB_TOKEN` or the git credential manager; `repo` scope is enough.
5. Sideload `artifacts/Head3DCapture.ipa` onto a Face ID iPhone using Sideloadly / AltStore / similar tools.

> The unsigned IPA contains an `arm64` device build without a signature; it only installs after you sign it (Sideloadly / AltStore / personal developer certificate).
