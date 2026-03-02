# FFmpeg Converter GTK

**Modern GTK4 + libadwaita frontend for FFmpeg**

My own pet project. FFmpeg-Converter-GTK a simple GTK / Libadwaita frontend for FFmpeg. Currently supports encoding with SVT-AV1, x265, x264, and VP9. Slowly but surely adding more supported codecs, features and refinement.

![Screenshot](Screenshot.png)

### Features

- Dedicated tabs for **SVT-AV1**, **x265**, **x264**, and **VP9** with deep encoder control
- Automatic crop detection for black bars, HDR to SDR tone mapping, scaling, rotation, speed control, and more
- Smart audio settings (Opus, AAC, MP3, FLAC, normalization, speed adjustment)
- Live console output and detailed information tab
- Extensive color and light correction and alteration. Full RGB manipulation.
- Crop & Trim tab that supports cutting, trimming, scrubbing, re-encoding, copy, creating individual and concatenate segments, and interactive cropping. Even cropping on a per segment basis + concatenate.
- Native Adwaita UI

### Dependency

```bash
meson, ninja, valac, pkg-config, GTK4, libadwaita
```

### Build & Install

```bash
git clone https://github.com/orlfman/FFmpeg-Converter-GTK.git
cd FFmpeg-Converter-GTK
chmod +x build.sh
./build.sh
```

### Uninstall

```bash
cd FFmpeg-Converter-GTK
chmod +x uninstall.sh
./uninstall.sh
```
