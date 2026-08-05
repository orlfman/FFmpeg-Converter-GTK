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
- Logo Removal — press **Detect Watermark** and it goes looking for a logo or watermark that sits in one spot, then paints it out with FFmpeg's `delogo`. You don't need to know where it is or how big it is. It handles solid and see-through overlays, logos jammed into a corner, banners that run off the side of the frame, and burned-in captions (the separate letters get merged into one box, so you don't end up with stencilled text). If the first quick pass finds nothing, it takes a second, closer look to catch small or faint captions. Whatever it finds lands in an editable box, so you can nudge it by hand instead of scanning again.
- Moving watermark detection — for logos that jump around. Most of them don't move constantly; they park in one corner for a while, then hop somewhere else. **Detect Moving** scans the whole video in short chunks and stitches the hits into timed regions (`start-end:x:y:w:h`, in that same editable box), so the removal follows the logo as it moves. Each hit is double-checked over its full stretch first, so ordinary scenery that happens to hold still doesn't get painted over. It reads the entire file instead of sampling it, so it's the slow one and stays opt-in.
- Neither of these is magic. Both work by spotting the parts of the picture that hold still, so a watermark that moves every single frame can't be pinned down, and one pressed right up against the edge of the frame gets found but cleaned up badly — `delogo` patches a box by reading inwards from its sides, and at the edge some of those sides aren't there. It'll tell you when that happens. Expect to nudge a box by hand now and then, and expect the occasional miss.
- Combine Videos — join multiple video files with copy mode (lossless, requires matching formats) or full re-encode mode with normalization. Supports crossfade transitions, chapter markers, drag-and-drop reordering, and metadata preservation.
- Generate Collage — pick any video and get a contact sheet out of it: twelve frames from 8% to 96% of the runtime, tiled into one 4×3 PNG saved next to the source file. Same image Preferences can write automatically after an encode, except this one works on files you already have and doesn't re-encode anything. Size is selectable in Preferences → General at 720p, 1080p, 2K or 4K — note that a 4×3 grid of 16:9 frames is a 64:27 picture, so 1080p means 1920×810 rather than 1920×1080.
- Audio codec support for AAC, FLAC, MP3, Opus, WAV, and Vorbis, with an option to keep all audio tracks or only the default track
- Live console output for debugging, and detailed information tab for video metadata
- Extensive color and light correction and alteration. Full RGB manipulation.
- Subtitles tab to reorder, remove, add, and extract subtitles.
- Crop & Trim tab that supports cutting, trimming, scrubbing, re-encoding, copy, creating individual and concatenate segments, and interactive cropping. Even cropping on a per segment basis + concatenate. The video player allows you to select regions within the video to select and crop. Also now has a Chapter Extraction mode to split chapters out of videos!
- By default the program uses the local systems FFmpeg but you can set custom path for FFmpeg if you wish to use a different version.
- Native Adwaita UI

## 🧠 Smart Optimizer

Tired of guessing your way to the perfect file size? Tell it a size — or a quality level, if that's what you actually care about — then press the **Smart Optimizer** button on the SVT-AV1, x265, x264 or VP9 tab, and the app handles everything else.

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

### Don't care about size, just want it to look right?

Set **Quality Ceiling** on the codec tab to anything other than *Off*, and the whole thing runs backwards: you choose the quality tier, and size becomes the prediction.

- **Low** — acceptable, maximum VMAF 88
- **Medium** — good, maximum VMAF 92
- **High** — visually near-transparent, maximum VMAF 95
- **Ultra** — archival, maximum VMAF 97

The number is a ceiling, not a bullseye or a minimum. The fitted curve chooses a starting CRF, then the optimizer measures that candidate. If the measured VMAF is above the selected ceiling, it raises CRF and measures again until the result is at or below the ceiling. Undershooting is allowed when an integral CRF step or the source itself cannot land exactly on the number; the optimizer keeps the closest result it can verify without crossing it.

Quality Ceiling and Target Size are mutually exclusive — whichever you select is the constraint, and the other value is reported as a prediction.

Re-encoding is copying: it can get very close to the original, but it can never come out better than it. Your source is the ceiling in terms of quality. You cannot go higher than a VMAF score of 100, and achieving a goal of 100 is incredibly hard as that's virtually lossless, and these codecs are not lossless codecs. To make it more difficult, the curve goes flat before you even start to reach 100. Trying to push to lossless quality, when you know ultimately, you cannot, isn't worth it. Achieving a VMAF score of 97 is the most practical goal for “Ultra” quality.

Worth knowing: VMAF is a model of human vision, not human vision. It's solid on live-action, shakier on animation, and it badly over-rates screen recordings — a 4K screen capture scores 92.7 at CRF 34 with the text visibly mangled. On content where the number can't be trusted the optimizer caps CRF by rule instead of pretending the score means something

### Just want to re-encode at the same size?
Flip **Match Source Size** on, right under the target box. The target locks to your source file's own size, rounded to the nearest whole MB (a 9.54 MB file targets 10 MB, a 14.53 MB file targets 15 MB), and follows along whenever you pick a different file. Handy when you don't care about shrinking anything — you just want the optimizer to re-encode into a better codec at roughly the size you started with. On the Crop & Trim tab each segment gets its own target measured from that segment, so a 10-second cut out of a 2 GB movie doesn't inherit the full 2 GB. There's a global override in **Preferences - Smart Optimizer** if you want every codec tab to start this way.

Remember, its not perfect. Its not artificial intelligence scanning in real time. Its all math at work making the best estimate based off mathematical values and statistics. But its high quality estimations and very accurate for just being math + statistics. From my testing, a solid 70-80% accuracy level. Give it a try! 

**No more encode, check size, re-encode, repeat.**  
Just pick the mode and go.

---

### Dependencies

Package names differ between distributions, but a source build needs:

- **Build tools:** GNU Make, Meson, Ninja, Vala, `pkg-config`, and a C compiler.
- **Development libraries:** GLib/GObject/GIO, GTK4, libadwaita, Cairo, Pango,
  JSON-GLib, libsoup 3, and libmpv.
- **Runtime:** FFmpeg (including FFprobe) and libmpv, which powers the in-app
  preview players and decodes through its own bundled FFmpeg libraries. The
  hicolor icon theme is also required for the installed application icon.
- **Optional:** FFmpeg's `libvmaf` filter enables Smart Optimizer Quality
  Target mode. FFplay enables the optional ffplay playback preference; the app
  falls back to the system player when it is unavailable.

The Makefile checks these capabilities before building and reports the missing
tool or library rather than assuming distribution-specific package names.

> The preview players use libmpv rather than GTK's GStreamer-backed
> `Gtk.MediaFile`. GStreamer is no longer required at all. See
> [`docs/upstream-gstreamer-playbin3-matroska-memory.md`](docs/upstream-gstreamer-playbin3-matroska-memory.md)
> for the memory defect that motivated the change.

### Dependencies (Arch Linux)

Install everything needed to build and run the application from source:

```bash
sudo pacman -S --needed base-devel meson ninja vala pkgconf gtk4 libadwaita \
  json-glib libsoup3 cairo pango ffmpeg mpv hicolor-icon-theme
```

On Arch, FFmpeg supplies FFmpeg, FFprobe, FFplay, and the `libvmaf`-enabled
filter used by Quality Target mode.

### Install (Arch Linux / AUR)

Available on the AUR as [`ffmpeg-converter-gtk`](https://aur.archlinux.org/packages/ffmpeg-converter-gtk). Install it with your favorite AUR helper:

```bash
yay -S ffmpeg-converter-gtk
```

### Install (from source)

Download the latest source release from [Releases](https://github.com/orlfman/FFmpeg-Converter-GTK/releases), extract it, then use the included Makefile:

```bash
cd FFmpeg-Converter-GTK-<version>
make
sudo make install
```

### Development Build & Install

A Git clone also includes the interactive `DevTools/build.sh` helper, which is
not included in release archives.

```bash
git clone https://github.com/orlfman/FFmpeg-Converter-GTK.git
cd FFmpeg-Converter-GTK                                                                                                                                                                                                    
make                                                      
sudo make install

or

cd FFmpeg-Converter-GTK/DevTools
./build.sh
```

### Side-by-side development build

To test changes without disturbing an installed copy (the AUR package, for
example), build the development profile:

```bash
./DevTools/build.sh --dev
```

This installs to `~/.local` — no sudo, and it cannot touch `/usr`. It gets its
own application ID, binary (`ffmpeg-converter-gtk-devel`), desktop entry
("FFmpeg Converter GTK (Development)") and settings directory
(`~/.config/FFmpeg-Converter-GTK-Devel`), so both versions run at the same time
with independent preferences.

The distinct application ID is the part that matters: GTK applications are
single-instance per ID, so a development build sharing the release ID would not
start at all — it would just raise the installed app's window while you assumed
you were testing your build.

Dev builds rebuild incrementally; pass `--clean` to start from scratch. To
remove it again:

```bash
./DevTools/uninstall.sh --dev
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
