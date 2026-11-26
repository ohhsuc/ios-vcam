# VCam — app-local experimental video source

This fork targets a user-controlled iOS camera test app in LiveContainer. It is not a system-wide camera driver.

## Manual build
The workflow supports manual dispatch in Actions → Build VCam → Run workflow. The source review commit skips CI; no build or device test has been performed for that commit. Download VCam-dylib after a successful manual build.

## Test sequence
1. Use a test app you control with AVCaptureVideoDataOutput; verify normal camera and UI without the plugin.
2. Load the dylib in LiveContainer. Tap and drag the camera button, open/close the menu, and cancel the picker.
3. Select a short local video using the system photo picker. Orange indicates loading; green indicates decoding is active, not that every camera consumer receives replacement frames.
4. Verify the app's actual video-data delegate output and frame dimensions, timestamps, playback speed, looping and memory use. Toggle off and verify real camera frames resume.
5. Repeat with portrait, landscape, invalid/unavailable videos, and background/foreground transitions.

## Known limitations
- Only AVCaptureVideoDataOutput callbacks registered after the hook loads are supported. Native AVCaptureVideoPreviewLayer, photo capture, audio, other/native capture paths, and arbitrary third-party apps are not guaranteed.
- Failed pixel conversion or unavailable source frames leave the original camera callback unchanged. No full-screen fake preview is used.
- iOS 16+ VideoToolbox is used to convert common frame formats; hardware/format support must be tested.
- No RTSP/RTMP/OBS, persistent selection, or global camera support. The old jailbreak settings bundle is not built; this fork has not validated the legacy deb installation path.
- LiveContainer and iOS 27.2 compatibility is unverified.
