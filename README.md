# FFmpeg Converter GTK

**Modern GTK4 + libadwaita frontend for FFmpeg**

My own pet project. FFmpeg-Converter-GTK a simple GTK / Libadwaita frontend for FFmpeg. Currently supports encoding with SVT-AV1, x265, x264, and VP9. Slowly but surely adding more supported codecs, features and refinement.

![Screenshot](Screenshots/Screenshot.png)

<details>
  <summary><h3>Screenshots</h3></summary>

  <table>
    <tr>
      <td align="center"><b>Main</b><br><img src="Screenshots/Screenshot.png" width="400"></td>
      <td align="center"><b>SVT-AV1</b><br><img src="Screenshots/Screenshot-SVT-AV1.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>x265</b><br><img src="Screenshots/Screenshot-x265.png" width="400"></td>
      <td align="center"><b>x264</b><br><img src="Screenshots/Screenshot-x264.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>VP9</b><br><img src="Screenshots/Screenshot-VP9.png" width="400"></td>
      <td align="center"><b>Subtitles</b><br><img src="Screenshots/Screenshot-Subtitles.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Crop</b><br><img src="Screenshots/Screenshot-Crop.png" width="400"></td>
      <td align="center"><b>Trim</b><br><img src="Screenshots/Screenshot-Trim.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Crop & Trim</b><br><img src="Screenshots/Screenshot-Crop-Trim.png" width="400"></td>
      <td align="center"><b>Information</b><br><img src="Screenshots/Screenshot-Information.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Console</b><br><img src="Screenshots/Screenshot-Console.png" width="400"></td>
      <td align="center"><b>Preferences</b><br><img src="Screenshots/Screenshot-Preferences.png" width="400"></td>
    </tr>
     <tr>
      <td align="center"><b>Color Correction</b><br><img src="Screenshots/Screenshot-ColorCorrection.png" width="400"></td>
      <td align="center"><b>Smart Optimizer Preferences</b><br><img src="Screenshots/Screenshot-SmartOptimizer-Settings.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Smart Optimizer</b><br><img src="Screenshots/Screenshot-SmartOptimizer.png" width="400"></td>
      <td align="center"><b>Smart Optimizer Invalid</b><br><img src="Screenshots/Screenshot-SmartOptimizer-Invalid.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Smart Optimizer Success</b><br><img src="Screenshots/Screenshot-SmartOptimizer-Success.png" width="400"></td>
      <td align="center"><b>Smart Optimizer File Size Reduction</b><br><img src="Screenshots/Screenshot-SmartOptimizer-Filesize-Reduction.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Smart Optimizer Crop & Trim Tab</b><br><img src="Screenshots/Screenshot-SmartOptimizer-CropTrimTab.png" width="400"></td>
      <td align="center"><b>Crop & Trim Chapter Exractation</b><br><img src="Screenshots/Screenshot-Chapter Split" width="400"></td>
    </tr>
  </table>

</details>

### Features

- Dedicated tabs for **SVT-AV1**, **x265**, **x264**, and **VP9** with deep encoder control
- Automatic, one-click crop detection for black bars, HDR to SDR tone mapping, scaling, rotation, speed control, and way more
- Audio codec support for AAC, FLAC, MP3, Opus, and Vorbis
- Live console output for debugging, and detailed information tab for video metadata
- Extensive color and light correction and alteration. Full RGB manipulation.
- Subtitles tab to reorder, remove, add, and extract subtitles.
- Crop & Trim tab that supports cutting, trimming, scrubbing, re-encoding, copy, creating individual and concatenate segments, and interactive cropping. Even cropping on a per segment basis + concatenate. The video player allows you to select regions within the video to select and crop. Also now has a Chapter Extraction mode to split chapters out of videos!
- By default the program uses the local systems FFmpeg but you can set custom path for FFmpeg if you wish to use a different version.
- Native Adwaita UI

## 🧠 Smart Optimizer

Tired of guessing your way to the perfect file size? Just pick **Smart Optimizer** from the Quality Profile dropdown on the x264 or VP9 tab, and the app handles everything else.

### How it actually works
It doesn’t rely on some magic lookup table. Instead, it runs **two quick calibration encodes** on *your specific video* at different quality levels, then fits a real exponential curve to the results. It also figures out whether you’re dealing with live-action, anime, or a screencast, and picks the perfect preset + CRF combo to land right on your target size.

### What it actually looks at
- **Your real content** — Anime with its flat colors and razor-sharp lines compresses totally differently from live-action. The optimizer checks edge density, color saturation, and motion to classify it properly, then uses the right preset table. Anime gets the aggressive (slow) presets it loves; live-action doesn’t waste time on settings that barely help.
- **Your actual filters** — Scaling, cropping, denoise, framerate changes… all of it gets baked into the test encodes so the size prediction matches what you’ll really export.
- **Trimmed length** — If you set start/end points on the General tab, it only budgets for the clip you’re actually keeping.
- **Audio** — It subtracts the real audio bitrate from your target so the video gets an honest budget (no more “whoops, audio ate 30% of my file” surprises).

### What you actually get
- A **CRF + preset recommendation** (best quality for the size)
- A **two-pass bitrate version** as a guaranteed-size backup
- A **confidence score** so you know how much the prediction had to guess
- Full calibration numbers dumped to the Console tab

### When it can’t hit the target
It won’t just give up. It tells you exactly why and what to change: “trim to 42 seconds” or “scale down to "X."”

You can set your default target size in **Preferences - Smart Optimizer**.

**No more encode, check size, re-encode, repeat.**  
Just pick the mode and go.

---

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

### Acknowledgments

This application is a frontend for [FFmpeg](https://ffmpeg.org) and does not bundle or distribute FFmpeg. 
FFmpeg is a trademark of [Fabrice Bellard](http://bellard.org/). 
Users are responsible for installing FFmpeg separately on their system.
