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
      <td align="center"><b>Crop & Trim Chapter Exractation</b><br><img src="Screenshots/Screenshot-Chapter Split.png" width="400"></td>
    </tr>
    <tr>
      <td align="center"><b>Audio Tab</b><br><img src="Screenshots/Screenshot-Audio-Tab.png" width="400"></td>
    </tr>
  </table>

</details>

### Features

- Dedicated tabs for **SVT-AV1**, **x265**, **x264**, and **VP9** with deep encoder control
- Automatic, one-click crop detection for black bars, HDR to SDR tone mapping, scaling, rotation, speed control, and way more
- Watermarking — text watermarks with configurable font, size, color, opacity, and position, plus an image watermark mode for logo overlays. Works across normal conversions, subtitle burn-in, and Crop & Trim re-encode paths.
- Logo Removal — one-click watermark detection and removal. Press **Detect Watermark** and the video is sampled across its length to find a station logo or watermark that stays in one place, then FFmpeg's `delogo` paints it out. No need to know where the watermark is or how big it is. Works on opaque and semi-transparent overlays, on logos tucked right into a corner, on banners that run off the edge of the frame, and on burned-in captions, whose separate letters are reassembled into one region so the text is not removed in stencil. If the quick scan finds nothing, the video is read a second time at double the detail, which recovers small or faint captions that get blurred away when the frame is shrunk for analysis — so a clean video costs one extra scan, and a watermarked one usually costs none. The detected region is shown as editable text, so a result can be nudged by hand instead of re-scanned. What it cannot do is lock onto a watermark that moves, drifts or changes — detection works by finding the parts of the picture that hold still. A drifting overlay leaves a wake that looks perfectly still but is blurred rather than sharp, and that blur is what gives it away, so those are reported as not found instead of being guessed at and painted over.
- Moving watermark detection — a second button for the logos the scan above is built to turn away. Most "moving" watermarks do not move continuously; they sit in one corner for a while and then jump, which means that over a few seconds at a time they hold perfectly still. **Detect Moving** reads the whole video in short windows, looks for a watermark in each one separately, and stitches the answers into timed regions, so removal switches on and off around the logo as it moves. Every candidate is then re-checked over its whole stretch before being offered: a short window contains little movement, and ordinary scenery holds still enough over four seconds to look like an overlay, so anything that cannot also hold up to a longer look is discarded rather than painted over. It reads the entire video instead of sampling three stretches of it, so it is the slower of the two and stays opt-in. Its results appear in the same editable Region box, as `start-end:x:y:w:h`. Two honest limits: a logo that moves every frame still cannot be pinned down, and a watermark against the edge of the frame is found accurately but removed badly, because `delogo` fills a rectangle by reading inwards from its sides and at an edge some of those sides do not exist — the result says so when it happens.
- Combine Videos — join multiple video files with copy mode (lossless, requires matching formats) or full re-encode mode with normalization. Supports crossfade transitions, chapter markers, drag-and-drop reordering, and metadata preservation.
- Audio codec support for AAC, FLAC, MP3, Opus, WAV, and Vorbis, with an option to keep all audio tracks or only the default track
- Live console output for debugging, and detailed information tab for video metadata
- Extensive color and light correction and alteration. Full RGB manipulation.
- Subtitles tab to reorder, remove, add, and extract subtitles.
- Crop & Trim tab that supports cutting, trimming, scrubbing, re-encoding, copy, creating individual and concatenate segments, and interactive cropping. Even cropping on a per segment basis + concatenate. The video player allows you to select regions within the video to select and crop. Also now has a Chapter Extraction mode to split chapters out of videos!
- By default the program uses the local systems FFmpeg but you can set custom path for FFmpeg if you wish to use a different version.
- Native Adwaita UI

## 🧠 Smart Optimizer

Tired of guessing your way to the perfect file size? Just press the **Smart Optimizer** button on the SVT-AV1, x265, x264 or VP9 tab, and the app handles everything else.

### How it actually works
It doesn’t rely on some magic lookup table. Instead, it runs **one to six (based off duration and content of the video) quick calibration encodes** on *your specific video* at different quality levels, then fits a real exponential curve to the results. It also figures out whether you’re dealing with live-action, anime, or a screencast, and picks the perfect preset + CRF or static bitrate combo to land right on your target size.

### What it actually looks at
- **Your real content** — Anime with its flat colors and razor-sharp lines compresses totally differently from live-action. The optimizer checks edge density, color saturation, and motion to classify it properly, then uses the right preset table. Anime gets the aggressive (slow) presets it loves; live-action doesn’t waste time on settings that barely help.
- **Your actual filters** — Scaling, cropping, denoise, framerate changes… all of it gets baked into the test encodes so the size prediction matches what you’ll really export.
- **Trimmed length** — If you set start/end points on the General tab, it only budgets for the clip you’re actually keeping.
- **Audio** — It subtracts the real audio bitrate from your target so the video gets an honest budget (no more “whoops, audio ate 30% of my file” surprises).

### What you actually get
- A **CRF or static bitrate + preset recommendation** (best quality for the size)
- A **two-pass bitrate version** as a guaranteed-size backup
- A **confidence score** so you know how much the prediction had to guess
- Full calibration numbers dumped to the Console tab

### When it can’t hit the target
It won’t just give up. It tells you exactly why and what to change: “trim to 42 seconds” or “scale down to "X."”

You can set your default target size in **Preferences - Smart Optimizer**.

Remember, its not perfect. Its not artificial intelligence scanning in real time. Its all math at work making the best estimate based off mathematical values and statistics. But its high quality estimations and very accurate for just being math + statistics. From my testing, a solid 70-80% accuracy level. Give it a try! 

**No more encode, check size, re-encode, repeat.**  
Just pick the mode and go.

---

### Dependency

```bash
meson, ninja, valac, pkg-config, GTK4, libadwaita, json-glib, FFmpeg, FFprobe, and GStreamer 
```

### Install (Arch Linux / AUR)

Available on the AUR as [`ffmpeg-converter-gtk`](https://aur.archlinux.org/packages/ffmpeg-converter-gtk). Install it with your favorite AUR helper:

```bash
yay -S ffmpeg-converter-gtk
```

### Install (from source)

Download the latest source release from [Releases](https://github.com/orlfman/FFmpeg-Converter-GTK/releases), extract it, then:

```bash
cd FFmpeg-Converter-GTK-<version>
make
sudo make install
```

### Development Build & Install

```bash
git clone https://github.com/orlfman/FFmpeg-Converter-GTK.git
cd FFmpeg-Converter-GTK                                                                                                                                                                                                    
make                                                      
sudo make install

or

cd FFmpeg-Converter-GTK/DevTools
./build.sh
```

### Uninstall

```bash
cd FFmpeg-Converter-GTK
make uninstall

or

cd FFmpeg-Converter-GTK/DevTools
./uninstall.sh
```

### Rebuild

```bash
cd FFmpeg-Converter-GTK
make rebuild

or

cd FFmpeg-Converter-GTK/DevTools
./build.sh
```

### Acknowledgments

This application is a frontend for [FFmpeg](https://ffmpeg.org) and does not bundle or distribute FFmpeg. 
FFmpeg is a trademark of [Fabrice Bellard](http://bellard.org/). 
Users are responsible for installing FFmpeg separately on their system.
