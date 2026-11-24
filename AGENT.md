# AGENT.md — Head3DCapture iOS Project & GitHub Actions Build Guide

## 1. Project Overview
`Head3DCapture` is a minimalist iOS SwiftUI + AVFoundation + Metal data collection application for the **Head3D** project.
It captures:
- Front **TrueDepth** camera RGB image (`rgb.jpg`)
- Uncompressed 32-bit float depth map (`depth.tiff`, unit: meters, `Float32` / `CV_32FC1` compatible)
- Scaled camera intrinsics & metadata (`intrinsics.json`)
- Real-time 3D point cloud visualization rendered via **Metal (`MTKView`)** with pan/pinch/double-tap gestures.

Saved captures are written to `Documents/Head3D/<timestamp>/` (one parent folder so everything is easy to find in the Files app) and exposed via iOS File Sharing (`UIFileSharingEnabled` and `LSSupportsOpeningInPlace` → 文件 App › 我的 iPhone › **Head3D采集** › Head3D). Because iOS gives an app no write access to arbitrary public folders, the UI also has a **导出** button that opens `UIDocumentPickerViewController(forExporting:)` to copy a capture folder anywhere (iCloud Drive / 我的 iPhone …).

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
   - `intrinsics.json` also records `rgb_width/rgb_height` (of `rgb.jpg`), `color_sampling_width/height` (live RGB stream), `reference_width/height`, `pixel_size_mm` and `extrinsic_depth_to_rgb_3x4` (see §5).
   - Keep `isDepthDataFiltered = false` and `depthDataOutput.isFilteringEnabled = false` unless explicitly asked to enable smoothing, so raw structured-light depth behavior is preserved.
   - The point-cloud **visualization** is rotated by `TrueDepthCaptureManager.pointCloudRotationDegrees` (90° clockwise) because TrueDepth depth maps are delivered in the sensor's landscape orientation. Saved files are **never** rotated — they stay sensor-native for the desktop pipeline.
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

---

## 5. 深度 ↔ RGB 外参与彩色点云
- iOS **没有**公开「前置 RGB 相机 ↔ 深度(IR) 传感器」的独立标定。唯一可用的是 `AVDepthData.cameraCalibrationData.extrinsicMatrix`（`matrix_float4x3`，`[R|t]`，语义是 **深度相机 → 参考相机(RGB)**）。对 TrueDepth，深度图已由系统配准到 RGB 参考相机，因此这个矩阵实测是（或近似）单位阵；`intrinsicMatrix` 也是按 `intrinsicMatrixReferenceDimensions`（即 RGB 参考分辨率）表达的，缩放到深度图分辨率后即为深度相机内参。
- 这正是彩色点云可行的原因：`buildPointCloud` 直接把深度像素 `(u,v)` 按宽度比例映射到实时 RGB 视频帧采样颜色（`kCVPixelFormatType_32BGRA`，由 `AVCaptureVideoDataOutput` 提供），无需做外参重投影；若将来确实拿到非单位外参，用它先把点变换到参考相机再用 `K_ref` 投影即可。
- UI 中「彩色深度点云 / 深度伪彩」切换对应 `TrueDepthCaptureManager.showColorPointCloud`；没有 RGB 帧时自动回退到深度伪彩。

