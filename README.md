# Spiggot

A macOS menu bar app that captures video from gphoto2-compatible cameras and outputs to Syphon for use in OBS, video software, or any Syphon client.

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

The app will appear as "GPhoto2 Camera" in any Syphon client.

## Using with OBS

1. Install the OBS Syphon plugin: https://github.com/zakk4223/obs-syphon
2. Add a new "Syphon Client" source
3. Select "Spiggot - GPhoto2 Camera"

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
