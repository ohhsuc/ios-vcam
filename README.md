# VCam — app-local experimental video source

This fork targets a user-controlled iOS camera test app in LiveContainer. It is not a system-wide camera driver.

## Manual build
The workflow supports manual dispatch in Actions → Build VCam → Run workflow. The initial source review commit skipped CI. The follow-up commit requests a CI build; device testing remains required. Minimum deployment target: iOS 16.0. Download VCam-dylib after a successful manual build.

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

## Performance branch (experimental)
- Per-output pixel-buffer pool, minimum count 3, allocation threshold 8. The pool is recreated on format or size changes; previously returned buffers remain owned by their consumers.
- The camera menu reports cumulative mean/peak frame preparation time (excluding the host callback), allocation threshold events, replacements and fallbacks since process launch.
- The original frame is forwarded if allocation or conversion fails, as before. A zero fallback count is a test target, not a guarantee. Test with non-sensitive scenes in an authorized test app.
- Compare identical clips and device settings against main, including switching cameras, repeated start/stop, background/foreground, and sustained memory use. No benchmark results or on-device verification are claimed.
- This branch does not alter source content, add random perturbations, or hide the plugin. Playback clock and decoding remain unchanged.
