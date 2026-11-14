This update fixes a crash, helps the app start faster and use less memory, and makes several video settings work the way they should.

### A smoother experience

- Fixed a crash when the app could not find or start FFmpeg.
- The app starts faster and uses less memory before you open its tabs.
- Crop & Trim stays responsive while preparing clips for the Smart Optimizer. You can cancel during this step, and unfinished temporary clips are cleaned up.
- Combining videos no longer freezes the window while looking up a title for the output filename.
- Changing settings while that lookup is running no longer mixes the old filename with the new encoding settings. The combine keeps the settings you chose when you clicked the button.
- Added a time limit to more video-information checks so they do not wait forever on a stalled file.

### Video settings that work as expected

- Fixed x264 conversions failing when CABAC or MB-Tree was turned off, or when using Baseline or Fast Decode.
- x264 presets and tunes now keep their intended settings when the advanced controls are left at their defaults. The labels explain when a control follows the preset or tune.
- Fixed x265 level selection and settings that were overriding its tunes and presets.
- SVT-AV1's Variance option now enables Variance Boost as intended.
- VP9 controls and descriptions now better reflect what the encoder can use, including which options need two-pass encoding.
- Improved the Smart Optimizer's x264 estimates by making its test encodes closer to the final conversion. The highest-effort tests can take longer as a result.
- Clarified lossless encoding: CRF 0 is lossless for 8-bit output. For 10-bit lossless output, use QP 0 with Profile set to Auto or High444.
