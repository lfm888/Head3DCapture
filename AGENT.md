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
├── .github/
│   └── workflows/
│       └── build-ipa.yml
└── Sources/
    ├── Head3DCaptureApp.swift
    ├── TrueDepthCaptureManager.swift
    └── PointCloudMetalView.swift
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
   - If adding new `.swift` files under `Sources/`, `xcodegen` automatically picks them up because `sources: - path: Sources` is configured.
   - If adding new Apple system frameworks, add `- sdk: <Framework>.framework` under `targets.Head3DCapture.dependencies` in `.github/workflows/build-ipa.yml`.

---

## 4. Pushing to GitHub & Triggering Build
1. Extract the archive into your target directory/repository.
2. Commit and push to `main` or `master` (or trigger `workflow_dispatch` manually in GitHub Actions):
   ```bash
   git add .
   git commit -m "Add Head3DCapture iOS app and IPA build workflow"
   git push origin main
   ```
3. Wait for the **Build Unsigned iOS IPA** workflow to finish, then download the `Head3DCapture-IPA` artifact from the workflow run summary.
4. Sideload `Head3DCapture.ipa` onto a Face ID iPhone using Sideloadly / AltStore / similar sideloading tools.
