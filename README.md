# Spiggot

A macOS menu bar app that captures video from gphoto2-compatible cameras and outputs it to Syphon and/or directly to OBS Studio's virtual camera, for use in video software, video calls, or any Syphon/system-camera client.

## Requirements

- macOS 26.0 or later
- Xcode 15+
- Homebrew
- A gphoto2-compatible camera (Canon, Nikon, Sony, etc.)

## Setup

### 1. Install gphoto2

```bash
brew install gphoto2
```

### 2. Install Syphon.framework

This project vendors `Syphon.framework` under `Frameworks/`. To (re)build it from source and copy it into the right place:

```bash
bash scripts/update_syphon_framework.sh
```

Or run the one-shot bootstrap (recommended):

```bash
bash scripts/bootstrap_deps.sh
```

Notes:
- Requires `git` and Xcode command line tools.
- By default it clones `https://github.com/Syphon/Syphon-Framework.git`.
- You can override with `SYPHON_REPO_URL` and/or `SYPHON_REF` (tag/branch).

### 3. Build the project

Open `Spiggot.xcodeproj` in Xcode and build (⌘B).

If you get header errors, verify the paths in Build Settings:
- **Header Search Paths**: Should include `/opt/homebrew/include` (Apple Silicon) or `/usr/local/include` (Intel)
- **Library Search Paths**: Should include `/opt/homebrew/lib` (Apple Silicon) or `/usr/local/lib` (Intel)

### 4. Run

1. Connect your camera via USB
2. Set camera to Manual (M) mode for best results
3. Launch Spiggot
4. Click the camera icon in the menu bar
5. Select "Start Capture"

The app will appear as "GPhoto2 Camera" in any Syphon client, and/or as "OBS Virtual Camera" system-wide if that output is enabled (see below).

## Outputs

Spiggot can publish frames to either or both of:

- **Syphon** ("GPhoto2 Camera") — for OBS (via a Syphon plugin), video-editing software, or any other Syphon client.
- **OBS Studio's virtual camera** — Spiggot pushes frames directly into OBS's own "OBS Camera Extension" device. This does **not** require OBS Studio to be running (or even open) — just installed and run once so its camera extension is activated on your Mac. Once activated, "OBS Virtual Camera" shows up as a regular system camera in *any* app (Zoom, Microsoft Teams, Photo Booth, QuickTime, etc.), not just inside OBS itself.

Toggle each independently from the menu bar: **Output: Syphon** / **Output: OBS Virtual Camera**. Syphon is on by default; OBS output is off by default since it requires OBS Studio to have been installed and run at least once.

Note: OBS's virtual camera device has a fixed 1920x1080 (16:9) canvas — Spiggot automatically crops to fill it with no letterboxing whenever this output is enabled (see Crop below). Syphon has no such restriction and always publishes at the camera's native preview resolution/aspect ratio.

## Using with OBS Studio directly (via Syphon)

1. Install the OBS Syphon plugin: https://github.com/zakk4223/obs-syphon
2. Add a new "Syphon Client" source
3. Select "Spiggot - GPhoto2 Camera"

## Crop, scale, and color

Open **Settings…** from the menu bar for a live-preview crop box (drag to move/resize, locked to 16:9 when OBS output is enabled so there's never any letterboxing) plus Hue/Saturation/Lightness sliders. All changes apply live and persist across launches; "Reset Crop" and "Reset Color" restore the defaults.

## Troubleshooting

### "Failed to initialize camera"

macOS's PTP camera daemons may grab the camera and prevent gphoto2 from claiming the USB interface.

This app will **always** best-effort stop those daemons and then retry `gp_camera_init` quickly.

If you want to verify who owns the USB interface from the CLI:

```bash
ioreg -l -w0 -r -c IOUSBHostInterface -k "USB Vendor Name" -k "USB Product Name" -k UsbExclusiveOwner | less
```

### Camera not detected

Run this to verify gphoto2 sees your camera:
```bash
gphoto2 --auto-detect
```

### Linker errors

Make sure gphoto2 is installed and the library paths are correct for your system:

**Apple Silicon (M1/M2/M3):**
- Header Search Paths: `/opt/homebrew/include`
- Library Search Paths: `/opt/homebrew/lib`

**Intel Mac:**
- Header Search Paths: `/usr/local/include`
- Library Search Paths: `/usr/local/lib`

## License

BSD 2-Clause License. See [LICENSE](LICENSE).

## Distribution

This project is set up so the built `.app` can be distributed as a single zip with no Homebrew runtime dependency.

- Syphon is embedded as `Syphon.framework`.
- libgphoto2 + its dependent dylibs are copied into the app’s `Contents/Frameworks/` during the build.
- libgphoto2 “camlibs” (camera drivers) are copied into `Contents/Resources/libgphoto2/camlibs/`.

To build a distributable zip:

```bash
bash scripts/package_release_zip.sh
```
