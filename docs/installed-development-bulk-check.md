# Installed development-app bulk check

Completed using the installed development executable on the actual desktop.
The executable matches the local development build. No code or installed files changed.

- Six real test videos, including portrait and landscape inputs with audio.
- Two complete folder runs: **12 outputs, zero conversion failures**.
- x264, 4 MB target per file, General half-size scaling and 24 fps.
- All twelve outputs decode fully without video/audio errors. Dimensions, frame rate,
  audio presence and durations match the requested transformations and sources.
- Convert again skips completed items. Rescan produces unique filenames and preserves
  the first six outputs byte-for-byte. Cancel stops further work and leaves saved files.
- Controls lock/unlock correctly. Source-specific page content is disabled; attempts
  to navigate into those pages return to General.
- Original source sizes, modification times and identities remain unchanged.
- No leftover active jobs, staging directories or passlogs. Test app closed normally.

The twelve converted files remain in the test folder's existing `output` directory.
Normal user preferences were isolated through temporary settings/cache paths.
This report and its commit include no media, screenshots or input/output filenames.

The test used a local driver of the installed app's existing UI handlers because
accessibility click activation was unreliable. Native file-chooser/mouse interaction
was not validated by this automation. Other codecs and quality mode retain earlier
synthetic test coverage. The separate mpv automated-test timeout remains unresolved.

Shared audit and handoff records: [AUDIT.md](AUDIT.md) and [CHANGELOG.md](CHANGELOG.md).
The findings report changes documentation only; no source changes were needed.
