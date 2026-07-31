project('ffmpeg-converter-gtk',
  ['vala', 'c'],
  version : '2.0.0',
  meson_version : '>= 0.62.0',
  default_options : [
    'warning_level=3',
    'buildtype=debugoptimized'
  ]
)
gnome = import('gnome')
fs = import('fs')
add_project_arguments('--target-glib=2.0', '--pkg=posix', language : 'vala')
# libmpv bindings live in-tree (no VAPI ships with mpv); mpv-compat.h sits in src/player/.
add_project_arguments(
  '--vapidir', meson.current_source_dir() / 'vapi',
  '--pkg=mpv',
  language : 'vala'
)
add_project_arguments('-I' + meson.current_source_dir() / 'src' / 'player', language : 'c')
headless_gtk_test_env = environment()
headless_gtk_test_env.set('DISPLAY', '')
headless_gtk_test_env.set('WAYLAND_DISPLAY', '')
headless_gtk_test_env.set('GSETTINGS_BACKEND', 'memory')
headless_gtk_test_env.set('GIO_USE_VFS', 'local')
display_gtk_test_env = environment()
display_gtk_test_env.set('GSETTINGS_BACKEND', 'memory')
display_gtk_test_env.set('GIO_USE_VFS', 'local')
hamburger_rebuild_test_env = environment()
hamburger_rebuild_test_env.set('GSETTINGS_BACKEND', 'memory')
hamburger_rebuild_test_env.set('GIO_USE_VFS', 'local')
hamburger_rebuild_test_env.set('G_DEBUG', 'fatal-warnings')
hamburger_rebuild_test_env.set('HAMBURGER_REBUILD_TEST', '1')
dependencies = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1', version : '>= 1.5'),
  dependency('json-glib-1.0'),
  dependency('libsoup-3.0'),
  dependency('mpv'),
]
sources = files(
  'src/app/main.vala',
  'src/runners/subprocess-compat.c',
  'src/player/mpv-compat.c',
  'src/player/mpv-backend.vala',
  'src/util/ffmpeg-runtime-capabilities.vala',
  'src/app/app-controller.vala',
  'src/runners/process-runner.vala',
  'src/util/conversion-utils.vala',
  'src/util/heap-trim.vala',
  'src/runners/operation-output-result.vala',
  'src/runners/progress-tracker.vala',
  'src/util/constants.vala',
  'src/encoders/svt-av1-tab.vala',
  'src/ui/general-tab.vala',
  'src/app/converter.vala',
  'src/ui/file-pickers.vala',
  'src/ui/path-breadcrumb.vala',
  'src/ui/status-area.vala',
  'src/ui/console-tab.vala',
  'src/encoders/filter-builder.vala',
  'src/encoders/logo-detector-logic.vala',
  'src/encoders/logo-detector.vala',
  'src/encoders/video-filters.vala',
  'src/encoders/svt-av1-builder.vala',
  'src/audio/audio-probe-types.vala',
  'src/audio/audio-source-info.vala',
  'src/audio/audio-compatibility.vala',
  'src/audio/audio-extract-logic.vala',
  'src/audio/audio-codec-settings.vala',
  'src/audio/audio-processing-settings.vala',
  'src/audio/audio-settings.vala',
  'src/runners/conversion-runner.vala',
  'src/encoders/codec-builder.vala',
  'src/encoders/x265-tab.vala',
  'src/encoders/x265-builder.vala',
  'src/encoders/codec-tab.vala',
  'src/encoders/base-codec-tab.vala',
  'src/ui/color-correction-dialog.vala',
  'src/ui/information-tab.vala',
  'src/ui/about-dialog.vala',
  'src/util/update-checker.vala',
  'src/player/playback-launcher-logic.vala',
  'src/ui/hamburger-menu.vala',
  'src/player/video-player.vala',
  'src/ui/crop-overlay.vala',
  'src/ui/trim-tab.vala',
  'src/encoders/trim-builder.vala',
  'src/runners/trim-runner.vala',
  'src/encoders/x264-tab.vala',
  'src/encoders/x264-builder.vala',
  'src/encoders/vp9-tab.vala',
  'src/encoders/vp9-builder.vala',
  'src/encoders/codec-presets.vala',
  'src/app/app-settings.vala',
  'src/ui/settings-dialog.vala',
  'src/util/subtitle-language-guesser.vala',
  'src/ui/subtitles-tab.vala',
  'src/runners/subtitles-runner.vala',
  'src/util/ffprobe-utils.vala',
  'src/encoders/codec-utils.vala',
  'src/optimizer/smart-optimizer-logic.vala',
  'src/optimizer/smart-optimizer-cache.vala',
  'src/optimizer/smart-optimizer.vala',
  'src/ui/audio-tab.vala',
  'src/player/audio-player.vala',
  'src/player/player-styles.vala',
  'src/ui/speed-menu-button.vala',
  'src/audio/audio-builder.vala',
  'src/runners/audio-runner.vala',
  'src/util/video-file-constants.vala',
  'src/ui/combine-window.vala',
  'src/runners/combine-runner.vala'
)

player_icon_resources = gnome.compile_resources(
  'player-icons',
  'Resources/player-icons.gresource.xml',
  source_dir : 'Resources',
  c_name : 'player_icons',
)
sources += player_icon_resources

executable('ffmpeg-converter-gtk',
  sources,
  dependencies : dependencies,
  link_args : ['-lm'],
  install : true,
  install_dir : get_option('bindir')
)

if fs.exists('tests/mpv-backend-state-test.vala')
  mpv_backend_state_test = executable(
    'mpv-backend-state-test',
    files(
      'src/player/mpv-compat.c',
      'src/player/mpv-backend.vala',
      'src/util/constants.vala',
      'src/app/app-settings.vala',
      'tests/mpv-backend-state-test.vala',
    ),
    dependencies : dependencies,
    vala_args : ['--define=MPV_BACKEND_STATE_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('mpv-backend-state', mpv_backend_state_test, env : headless_gtk_test_env)
endif

if fs.exists('tests/mpv-render-timing-test.c')
  # C only, and the software render API needs no display, so this runs headless
  # unlike the widget tests. It plays real media, hence the longer timeout.
  mpv_render_timing_test = executable(
    'mpv-render-timing-test',
    files(
      'src/player/mpv-compat.c',
      'tests/mpv-render-timing-test.c',
    ),
    dependencies : [dependency('glib-2.0'), dependency('mpv')],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test(
    'mpv-render-timing',
    mpv_render_timing_test,
    env : headless_gtk_test_env,
    is_parallel : false,
    timeout : 180,
  )
endif

# ── DevTools probes ─────────────────────────────────────────────────────────
#
# Not tests: they need real media and are read by a human. They are declared
# here so the documented build commands cannot drift out of date the way
# mpv-backend-probe.vala's did — that one is Vala and pulls in AppSettings and
# its supporting types, which a hand-written valac line has to keep chasing.
#
# build_by_default : false, so `make build` never compiles them. Build one with
#   meson compile -C builddir mpv-backend-probe
probe_targets = []

if fs.exists('DevTools/mpv-backend-probe.vala')
  probe_targets += executable(
    'mpv-backend-probe',
    files(
      'src/player/mpv-compat.c',
      'src/player/mpv-backend.vala',
      'src/util/constants.vala',
      'src/app/app-settings.vala',
      'DevTools/mpv-backend-probe.vala',
    ),
    dependencies : dependencies,
    build_by_default : false,
    link_args : ['-lm'],
  )
endif

# The two C probes need only the compatibility shim, which is why their header
# build commands still work standalone. Declared anyway so all three are built
# and kept compiling the same way.
foreach probe : [
  ['mpv-render-probe',        'DevTools/mpv-render-probe.c'],
  ['mpv-render-timing-probe', 'DevTools/mpv-render-timing-probe.c'],
]
  if fs.exists(probe[1])
    probe_targets += executable(
      probe[0],
      files('src/player/mpv-compat.c', probe[1]),
      dependencies : [dependency('glib-2.0'), dependency('mpv')],
      build_by_default : false,
      link_args : ['-lm'],
    )
  endif
endforeach

if probe_targets.length() > 0
  alias_target('probes', probe_targets)
endif

if fs.exists('tests/playback-launcher-logic-test.vala')
  playback_launcher_logic_test = executable(
    'playback-launcher-logic-test',
    files(
      'src/player/playback-launcher-logic.vala',
      'tests/playback-launcher-logic-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
    ],
    build_by_default : false,
  )

  test('playback-launcher-logic', playback_launcher_logic_test)
endif

if fs.exists('tests/update-checker-test.vala')
  update_checker_test = executable(
    'update-checker-test',
    files(
      'src/util/update-checker.vala',
      'tests/update-checker-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gio-2.0'),
      dependency('json-glib-1.0'),
      dependency('libsoup-3.0'),
    ],
    build_by_default : false,
  )

  test('update-checker', update_checker_test)
endif

install_data(
  'Resources/ffmpeg-converter-gtk.desktop',
  install_dir : get_option('datadir') / 'applications'
)

install_data(
  'Resources/ffmpeg-converter-gtk.svg',
  install_dir : get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

if fs.exists('tests/subtitle-language-guesser-test.vala')
  subtitle_language_guesser_test = executable(
    'subtitle-language-guesser-test',
    files(
      'src/util/subtitle-language-guesser.vala',
      'tests/subtitle-language-guesser-test.vala',
    ),
    vala_args : ['--define=SUBTITLE_LANGUAGE_GUESSER_TEST_BUILD'],
    build_by_default : false,
    dependencies : [
      dependency('glib-2.0'),
      dependency('gio-2.0'),
      dependency('json-glib-1.0'),
    ],
  )

  test('subtitle-language-guesser', subtitle_language_guesser_test)
endif

if fs.exists('tests/heap-trim-policy-test.vala')
  heap_trim_policy_test = executable(
    'heap-trim-policy-test',
    files(
      'src/util/heap-trim.vala',
      'tests/heap-trim-policy-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
    ],
    build_by_default : false,
  )

  test('heap-trim-policy', heap_trim_policy_test)
endif

if fs.exists('tests/logo-detector-logic-test.vala')
  logo_detector_logic_test = executable(
    'logo-detector-logic-test',
    files(
      'src/encoders/logo-detector-logic.vala',
      'tests/logo-detector-logic-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
    ],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('logo-detector-logic', logo_detector_logic_test)
endif

if fs.exists('tests/audio-builder-test.vala')
  audio_builder_test = executable(
    'audio-builder-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-builder.vala',
      'tests/audio-builder-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
    ],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('audio-builder', audio_builder_test)
endif

if fs.exists('tests/audio-add-builder-test.vala')
  audio_add_builder_test = executable(
    'audio-add-builder-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-builder.vala',
      'tests/audio-add-builder-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
    ],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('audio-add-builder', audio_add_builder_test)
endif

if fs.exists('tests/audio-reorder-test.vala')
  audio_reorder_test = executable(
    'audio-reorder-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-builder.vala',
      'tests/audio-reorder-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
    ],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('audio-reorder', audio_reorder_test)
endif

if fs.exists('tests/audio-settings-test.vala')
  audio_settings_test = executable(
    'audio-settings-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-builder.vala',
      'tests/audio-settings-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
    ],
    vala_args : ['--define=AUDIO_SETTINGS_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('audio-settings', audio_settings_test, env : headless_gtk_test_env)
endif

if fs.exists('tests/audio-extract-logic-test.vala')
  audio_extract_logic_test = executable(
    'audio-extract-logic-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-builder.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-processing-settings.vala',
      'tests/audio-extract-logic-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
    ],
    build_by_default : false,
  )

  test('audio-extract-logic', audio_extract_logic_test)
endif

if fs.exists('tests/ffprobe-utils-test.vala')
  ffprobe_utils_test = executable(
    'ffprobe-utils-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-builder.vala',
      'src/audio/audio-processing-settings.vala',
      'src/runners/subprocess-compat.c',
      'src/util/ffprobe-utils.vala',
      'tests/ffprobe-utils-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gio-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
      dependency('json-glib-1.0'),
    ],
    vala_args : ['--define=FFPROBE_UTILS_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('ffprobe-utils', ffprobe_utils_test)
endif

if fs.exists('tests/trim-subtitles-state-test.vala')
  trim_subtitles_state_test = executable(
    'trim-subtitles-state-test',
    files(
      'src/runners/subprocess-compat.c',
      'src/player/mpv-compat.c',
      'src/player/mpv-backend.vala',
      'src/util/ffmpeg-runtime-capabilities.vala',
      'src/runners/process-runner.vala',
      'src/util/conversion-utils.vala',
      'src/runners/operation-output-result.vala',
      'src/runners/progress-tracker.vala',
      'src/util/constants.vala',
      'src/encoders/svt-av1-tab.vala',
      'src/ui/general-tab.vala',
      'src/app/converter.vala',
      'src/ui/file-pickers.vala',
      'src/ui/path-breadcrumb.vala',
      'src/ui/status-area.vala',
      'src/ui/console-tab.vala',
      'src/encoders/filter-builder.vala',
      'src/encoders/logo-detector-logic.vala',
      'src/encoders/logo-detector.vala',
      'src/encoders/video-filters.vala',
      'src/encoders/svt-av1-builder.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-settings.vala',
      'src/runners/conversion-runner.vala',
      'src/encoders/codec-builder.vala',
      'src/encoders/x265-tab.vala',
      'src/encoders/x265-builder.vala',
      'src/encoders/codec-tab.vala',
      'src/encoders/base-codec-tab.vala',
      'src/ui/color-correction-dialog.vala',
      'src/ui/information-tab.vala',
      'src/ui/about-dialog.vala',
      'src/util/update-checker.vala',
      'src/player/playback-launcher-logic.vala',
      'src/ui/hamburger-menu.vala',
      'src/player/video-player.vala',
      'src/ui/crop-overlay.vala',
      'src/ui/trim-tab.vala',
      'src/encoders/trim-builder.vala',
      'src/runners/trim-runner.vala',
      'src/encoders/x264-tab.vala',
      'src/encoders/x264-builder.vala',
      'src/encoders/vp9-tab.vala',
      'src/encoders/vp9-builder.vala',
      'src/encoders/codec-presets.vala',
      'src/app/app-settings.vala',
      'src/ui/settings-dialog.vala',
      'src/util/subtitle-language-guesser.vala',
      'src/ui/subtitles-tab.vala',
      'src/runners/subtitles-runner.vala',
      'src/util/ffprobe-utils.vala',
      'src/encoders/codec-utils.vala',
      'src/optimizer/smart-optimizer-logic.vala',
      'src/optimizer/smart-optimizer-cache.vala',
      'src/optimizer/smart-optimizer.vala',
      'src/ui/audio-tab.vala',
      'src/player/audio-player.vala',
      'src/player/player-styles.vala',
      'src/ui/speed-menu-button.vala',
      'src/audio/audio-builder.vala',
      'src/runners/audio-runner.vala',
      'src/util/video-file-constants.vala',
      'tests/trim-subtitles-state-test.vala',
    ),
    dependencies : dependencies,
    vala_args : ['--define=TRIM_SUBTITLES_STATE_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('trim-subtitles-state', trim_subtitles_state_test)
endif

if fs.exists('tests/combine-window-state-test.vala')
  combine_window_state_test = executable(
    'combine-window-state-test',
    files(
      'src/runners/subprocess-compat.c',
      'src/player/mpv-compat.c',
      'src/player/mpv-backend.vala',
      'src/util/ffmpeg-runtime-capabilities.vala',
      'src/runners/process-runner.vala',
      'src/util/conversion-utils.vala',
      'src/runners/operation-output-result.vala',
      'src/runners/progress-tracker.vala',
      'src/util/constants.vala',
      'src/encoders/svt-av1-tab.vala',
      'src/ui/general-tab.vala',
      'src/app/converter.vala',
      'src/ui/file-pickers.vala',
      'src/ui/path-breadcrumb.vala',
      'src/ui/status-area.vala',
      'src/ui/console-tab.vala',
      'src/encoders/filter-builder.vala',
      'src/encoders/logo-detector-logic.vala',
      'src/encoders/logo-detector.vala',
      'src/encoders/video-filters.vala',
      'src/encoders/svt-av1-builder.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-settings.vala',
      'src/runners/conversion-runner.vala',
      'src/encoders/codec-builder.vala',
      'src/encoders/x265-tab.vala',
      'src/encoders/x265-builder.vala',
      'src/encoders/codec-tab.vala',
      'src/encoders/base-codec-tab.vala',
      'src/ui/color-correction-dialog.vala',
      'src/ui/information-tab.vala',
      'src/ui/about-dialog.vala',
      'src/util/update-checker.vala',
      'src/player/playback-launcher-logic.vala',
      'src/ui/hamburger-menu.vala',
      'src/player/video-player.vala',
      'src/ui/crop-overlay.vala',
      'src/ui/trim-tab.vala',
      'src/encoders/trim-builder.vala',
      'src/runners/trim-runner.vala',
      'src/encoders/x264-tab.vala',
      'src/encoders/x264-builder.vala',
      'src/encoders/vp9-tab.vala',
      'src/encoders/vp9-builder.vala',
      'src/encoders/codec-presets.vala',
      'src/app/app-settings.vala',
      'src/ui/settings-dialog.vala',
      'src/util/subtitle-language-guesser.vala',
      'src/ui/subtitles-tab.vala',
      'src/runners/subtitles-runner.vala',
      'src/util/ffprobe-utils.vala',
      'src/encoders/codec-utils.vala',
      'src/optimizer/smart-optimizer-logic.vala',
      'src/optimizer/smart-optimizer-cache.vala',
      'src/optimizer/smart-optimizer.vala',
      'src/ui/audio-tab.vala',
      'src/player/audio-player.vala',
      'src/player/player-styles.vala',
      'src/ui/speed-menu-button.vala',
      'src/audio/audio-builder.vala',
      'src/runners/audio-runner.vala',
      'src/util/video-file-constants.vala',
      'src/ui/combine-window.vala',
      'src/runners/combine-runner.vala',
      'tests/combine-window-state-test.vala',
    ),
    player_icon_resources,
    dependencies : dependencies,
    vala_args : [
      '--define=COMBINE_WINDOW_TEST_BUILD',
      '--define=MPV_BACKEND_STATE_TEST_BUILD',
    ],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('combine-window-state', combine_window_state_test, env : headless_gtk_test_env)
  # This path needs a real GTK frame clock, so do not force it through the
  # headless environment used by the broad widget/state suite. It runs as part
  # of the normal test set when a display is available and reports an explicit
  # skip otherwise.
  test(
    'mpv-player-display-state',
    combine_window_state_test,
    args : [
      '-p', '/players/video/failed-load-releases-backend-resources',
      '-p', '/players/video/disables-mpv-timing-lookahead',
    ],
    env : display_gtk_test_env,
    is_parallel : false,
    timeout : 30,
  )
  # Widget-state only — no mpv core — but constructing a player still needs GTK
  # to initialize, so this follows the same display-or-skip rule as above.
  test(
    'player-speed-selection',
    combine_window_state_test,
    args : [
      '-p', '/players/video/speed-resets-per-preview',
      '-p', '/players/audio/speed-resets-per-preview',
      '-p', '/players/video/speed-reaches-mpv-without-scaling-time',
    ],
    env : display_gtk_test_env,
    is_parallel : false,
    timeout : 60,
  )
  test(
    'preview-fullscreen-state',
    combine_window_state_test,
    args : [
      '-p', '/players/video/fullscreen-control-state',
      '-p', '/players/video/fullscreen-shortcut-releases-player',
      '-p', '/combine/widgets/preview-player-releases-on-close',
      '-p', '/combine/widgets/preview-fullscreen-window-state',
      '-p', '/trim/widgets/preview-fullscreen-window-state',
    ],
    env : display_gtk_test_env,
    is_parallel : false,
    timeout : 30,
  )
  test(
    'hamburger-recent-menu-rebuild',
    combine_window_state_test,
    args : [
      '-p', '/hamburger/recent-inputs/repeated-refresh-is-stable',
    ],
    env : hamburger_rebuild_test_env,
    is_parallel : false,
    timeout : 30,
  )
endif

if fs.exists('tests/audio-reorder-state-test.vala')
  audio_reorder_state_test = executable(
    'audio-reorder-state-test',
    files(
      'src/runners/subprocess-compat.c',
      'src/player/mpv-compat.c',
      'src/player/mpv-backend.vala',
      'src/util/ffmpeg-runtime-capabilities.vala',
      'src/runners/process-runner.vala',
      'src/util/conversion-utils.vala',
      'src/runners/operation-output-result.vala',
      'src/runners/progress-tracker.vala',
      'src/util/constants.vala',
      'src/encoders/svt-av1-tab.vala',
      'src/ui/general-tab.vala',
      'src/app/converter.vala',
      'src/ui/file-pickers.vala',
      'src/ui/path-breadcrumb.vala',
      'src/ui/status-area.vala',
      'src/ui/console-tab.vala',
      'src/encoders/filter-builder.vala',
      'src/encoders/logo-detector-logic.vala',
      'src/encoders/logo-detector.vala',
      'src/encoders/video-filters.vala',
      'src/encoders/svt-av1-builder.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-settings.vala',
      'src/runners/conversion-runner.vala',
      'src/encoders/codec-builder.vala',
      'src/encoders/x265-tab.vala',
      'src/encoders/x265-builder.vala',
      'src/encoders/codec-tab.vala',
      'src/encoders/base-codec-tab.vala',
      'src/ui/color-correction-dialog.vala',
      'src/ui/information-tab.vala',
      'src/ui/about-dialog.vala',
      'src/util/update-checker.vala',
      'src/player/playback-launcher-logic.vala',
      'src/ui/hamburger-menu.vala',
      'src/player/video-player.vala',
      'src/ui/crop-overlay.vala',
      'src/ui/trim-tab.vala',
      'src/encoders/trim-builder.vala',
      'src/runners/trim-runner.vala',
      'src/encoders/x264-tab.vala',
      'src/encoders/x264-builder.vala',
      'src/encoders/vp9-tab.vala',
      'src/encoders/vp9-builder.vala',
      'src/encoders/codec-presets.vala',
      'src/app/app-settings.vala',
      'src/ui/settings-dialog.vala',
      'src/util/subtitle-language-guesser.vala',
      'src/ui/subtitles-tab.vala',
      'src/runners/subtitles-runner.vala',
      'src/util/ffprobe-utils.vala',
      'src/encoders/codec-utils.vala',
      'src/optimizer/smart-optimizer-logic.vala',
      'src/optimizer/smart-optimizer-cache.vala',
      'src/optimizer/smart-optimizer.vala',
      'src/ui/audio-tab.vala',
      'src/player/audio-player.vala',
      'src/player/player-styles.vala',
      'src/ui/speed-menu-button.vala',
      'src/audio/audio-builder.vala',
      'src/runners/audio-runner.vala',
      'src/util/video-file-constants.vala',
      'tests/audio-reorder-state-test.vala',
    ),
    dependencies : dependencies,
    vala_args : ['--define=AUDIO_REORDER_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('audio-reorder-state', audio_reorder_state_test)
endif

if fs.exists('tests/smart-optimizer-logic-test.vala')
  smart_optimizer_logic_test = executable(
    'smart-optimizer-logic-test',
    files(
      'src/util/constants.vala',
      'src/audio/audio-probe-types.vala',
      'src/audio/audio-source-info.vala',
      'src/audio/audio-compatibility.vala',
      'src/audio/audio-settings.vala',
      'src/audio/audio-extract-logic.vala',
      'src/audio/audio-codec-settings.vala',
      'src/audio/audio-processing-settings.vala',
      'src/audio/audio-builder.vala',
      'src/optimizer/smart-optimizer-logic.vala',
      'src/optimizer/smart-optimizer-cache.vala',
      'tests/smart-optimizer-logic-test.vala',
    ),
    dependencies : [
      dependency('glib-2.0'),
      dependency('gobject-2.0'),
      dependency('gio-2.0'),
      dependency('gtk4'),
      dependency('libadwaita-1'),
      dependency('json-glib-1.0'),
    ],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('smart-optimizer-logic', smart_optimizer_logic_test)
endif
