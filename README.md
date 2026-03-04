# FFmpeg Converter GTK

**Modern GTK4 + libadwaita frontend for FFmpeg**

My own pet project. FFmpeg-Converter-GTK a simple GTK / Libadwaita frontend for FFmpeg. Currently supports encoding with SVT-AV1, x265, x264, and VP9. Slowly but surely adding more supported codecs, features and refinement.

![Screenshot](Screenshot.png)

### Features

- Dedicated tabs for **SVT-AV1**, **x265**, **x264**, and **VP9** with deep encoder control
- Automatic, one-click crop detection for black bars, HDR to SDR tone mapping, scaling, rotation, speed control, and way more
- Audio codec support for AAC, FLAC, MP3, Opus, and Vorbis
- Live console output for debugging, and detailed information tab for video metadata
- Extensive color and light correction and alteration. Full RGB manipulation.
- Subtitles tab to reorder, remove, add, and extract subtitles.
- Crop & Trim tab that supports cutting, trimming, scrubbing, re-encoding, copy, creating individual and concatenate segments, and interactive cropping. Even cropping on a per segment basis + concatenate. The video player allows you to select regions within the video to select and crop.
- By default the program uses the local systems FFmpeg but you can set custom path for FFmpeg if you wish to use a different version.
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
