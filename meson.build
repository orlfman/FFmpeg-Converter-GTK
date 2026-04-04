project('ffmpeg-converter-gtk',
  ['vala', 'c'],
  version : '1.5.6',
  meson_version : '>= 0.62.0',
  default_options : [
    'warning_level=3',
    'buildtype=debugoptimized'
  ]
)
gnome = import('gnome')
fs = import('fs')
add_project_arguments('--target-glib=2.0', '--pkg=posix', language : 'vala')
dependencies = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1'),
  dependency('json-glib-1.0'),
]
sources = files(
  'src/main.vala',
  'src/subprocess-compat.c',
  'src/ffmpeg-runtime-capabilities.vala',
  'src/app-controller.vala',
  'src/process-runner.vala',
  'src/conversion-utils.vala',
  'src/operation-output-result.vala',
  'src/progress-tracker.vala',
  'src/constants.vala',
  'src/svt-av1-tab.vala',
  'src/general-tab.vala',
  'src/converter.vala',
  'src/file-pickers.vala',
  'src/path-breadcrumb.vala',
  'src/status-area.vala',
  'src/console-tab.vala',
  'src/filter-builder.vala',
  'src/video-filters.vala',
  'src/svt-av1-builder.vala',
  'src/audio-probe-types.vala',
  'src/audio-source-info.vala',
  'src/audio-compatibility.vala',
  'src/audio-extract-logic.vala',
  'src/audio-codec-settings.vala',
  'src/audio-processing-settings.vala',
  'src/audio-settings.vala',
  'src/conversion-runner.vala',
  'src/codec-builder.vala',
  'src/x265-tab.vala',
  'src/x265-builder.vala',
  'src/codec-tab.vala',
  'src/base-codec-tab.vala',
  'src/color-correction-dialog.vala',
  'src/information-tab.vala',
  'src/about-dialog.vala',
  'src/hamburger-menu.vala',
  'src/video-player.vala',
  'src/crop-overlay.vala',
  'src/trim-tab.vala',
  'src/trim-builder.vala',
  'src/trim-runner.vala',
  'src/x264-tab.vala',
  'src/x264-builder.vala',
  'src/vp9-tab.vala',
  'src/vp9-builder.vala',
  'src/codec-presets.vala',
  'src/app-settings.vala',
  'src/settings-dialog.vala',
  'src/subtitle-language-guesser.vala',
  'src/subtitles-tab.vala',
  'src/subtitles-runner.vala',
  'src/ffprobe-utils.vala',
  'src/codec-utils.vala',
  'src/smart-optimizer.vala',
  'src/audio-tab.vala',
  'src/audio-player.vala',
  'src/player-styles.vala',
  'src/audio-builder.vala',
  'src/audio-runner.vala',
  'src/video-file-constants.vala',
  'src/combine-window.vala',
  'src/combine-runner.vala'
)
executable('ffmpeg-converter-gtk',
  sources,
  dependencies : dependencies,
  link_args : ['-lm'],
  install : true,
  install_dir : get_option('bindir')
)

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
      'src/subtitle-language-guesser.vala',
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

if fs.exists('tests/audio-builder-test.vala')
  audio_builder_test = executable(
    'audio-builder-test',
    files(
      'src/constants.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-settings.vala',
      'src/audio-extract-logic.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-builder.vala',
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
      'src/constants.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-settings.vala',
      'src/audio-extract-logic.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-builder.vala',
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
      'src/constants.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-settings.vala',
      'src/audio-extract-logic.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-builder.vala',
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
      'src/constants.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-settings.vala',
      'src/audio-builder.vala',
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

  test('audio-settings', audio_settings_test)
endif

if fs.exists('tests/audio-extract-logic-test.vala')
  audio_extract_logic_test = executable(
    'audio-extract-logic-test',
    files(
      'src/constants.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-codec-settings.vala',
      'src/audio-settings.vala',
      'src/audio-builder.vala',
      'src/audio-extract-logic.vala',
      'src/audio-processing-settings.vala',
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
      'src/constants.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-codec-settings.vala',
      'src/audio-settings.vala',
      'src/audio-extract-logic.vala',
      'src/audio-builder.vala',
      'src/audio-processing-settings.vala',
      'src/subprocess-compat.c',
      'src/ffprobe-utils.vala',
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
      'src/subprocess-compat.c',
      'src/ffmpeg-runtime-capabilities.vala',
      'src/process-runner.vala',
      'src/conversion-utils.vala',
      'src/operation-output-result.vala',
      'src/progress-tracker.vala',
      'src/constants.vala',
      'src/svt-av1-tab.vala',
      'src/general-tab.vala',
      'src/converter.vala',
      'src/file-pickers.vala',
      'src/path-breadcrumb.vala',
      'src/status-area.vala',
      'src/console-tab.vala',
      'src/filter-builder.vala',
      'src/video-filters.vala',
      'src/svt-av1-builder.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-extract-logic.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-settings.vala',
      'src/conversion-runner.vala',
      'src/codec-builder.vala',
      'src/x265-tab.vala',
      'src/x265-builder.vala',
      'src/codec-tab.vala',
      'src/base-codec-tab.vala',
      'src/color-correction-dialog.vala',
      'src/information-tab.vala',
      'src/about-dialog.vala',
      'src/hamburger-menu.vala',
      'src/video-player.vala',
      'src/crop-overlay.vala',
      'src/trim-tab.vala',
      'src/trim-builder.vala',
      'src/trim-runner.vala',
      'src/x264-tab.vala',
      'src/x264-builder.vala',
      'src/vp9-tab.vala',
      'src/vp9-builder.vala',
      'src/codec-presets.vala',
      'src/app-settings.vala',
      'src/settings-dialog.vala',
      'src/subtitle-language-guesser.vala',
      'src/subtitles-tab.vala',
      'src/subtitles-runner.vala',
      'src/ffprobe-utils.vala',
      'src/codec-utils.vala',
      'src/smart-optimizer.vala',
      'src/audio-tab.vala',
      'src/audio-player.vala',
      'src/player-styles.vala',
      'src/audio-builder.vala',
      'src/audio-runner.vala',
      'src/video-file-constants.vala',
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
      'src/subprocess-compat.c',
      'src/ffmpeg-runtime-capabilities.vala',
      'src/process-runner.vala',
      'src/conversion-utils.vala',
      'src/operation-output-result.vala',
      'src/progress-tracker.vala',
      'src/constants.vala',
      'src/svt-av1-tab.vala',
      'src/general-tab.vala',
      'src/converter.vala',
      'src/file-pickers.vala',
      'src/path-breadcrumb.vala',
      'src/status-area.vala',
      'src/console-tab.vala',
      'src/filter-builder.vala',
      'src/video-filters.vala',
      'src/svt-av1-builder.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-extract-logic.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-settings.vala',
      'src/conversion-runner.vala',
      'src/codec-builder.vala',
      'src/x265-tab.vala',
      'src/x265-builder.vala',
      'src/codec-tab.vala',
      'src/base-codec-tab.vala',
      'src/color-correction-dialog.vala',
      'src/information-tab.vala',
      'src/about-dialog.vala',
      'src/hamburger-menu.vala',
      'src/video-player.vala',
      'src/crop-overlay.vala',
      'src/trim-tab.vala',
      'src/trim-builder.vala',
      'src/trim-runner.vala',
      'src/x264-tab.vala',
      'src/x264-builder.vala',
      'src/vp9-tab.vala',
      'src/vp9-builder.vala',
      'src/codec-presets.vala',
      'src/app-settings.vala',
      'src/settings-dialog.vala',
      'src/subtitle-language-guesser.vala',
      'src/subtitles-tab.vala',
      'src/subtitles-runner.vala',
      'src/ffprobe-utils.vala',
      'src/codec-utils.vala',
      'src/smart-optimizer.vala',
      'src/audio-tab.vala',
      'src/audio-player.vala',
      'src/player-styles.vala',
      'src/audio-builder.vala',
      'src/audio-runner.vala',
      'src/video-file-constants.vala',
      'src/combine-window.vala',
      'src/combine-runner.vala',
      'tests/combine-window-state-test.vala',
    ),
    dependencies : dependencies,
    vala_args : ['--define=COMBINE_WINDOW_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('combine-window-state', combine_window_state_test)
endif

if fs.exists('tests/audio-reorder-state-test.vala')
  audio_reorder_state_test = executable(
    'audio-reorder-state-test',
    files(
      'src/subprocess-compat.c',
      'src/ffmpeg-runtime-capabilities.vala',
      'src/process-runner.vala',
      'src/conversion-utils.vala',
      'src/operation-output-result.vala',
      'src/progress-tracker.vala',
      'src/constants.vala',
      'src/svt-av1-tab.vala',
      'src/general-tab.vala',
      'src/converter.vala',
      'src/file-pickers.vala',
      'src/path-breadcrumb.vala',
      'src/status-area.vala',
      'src/console-tab.vala',
      'src/filter-builder.vala',
      'src/video-filters.vala',
      'src/svt-av1-builder.vala',
      'src/audio-probe-types.vala',
      'src/audio-source-info.vala',
      'src/audio-compatibility.vala',
      'src/audio-extract-logic.vala',
      'src/audio-codec-settings.vala',
      'src/audio-processing-settings.vala',
      'src/audio-settings.vala',
      'src/conversion-runner.vala',
      'src/codec-builder.vala',
      'src/x265-tab.vala',
      'src/x265-builder.vala',
      'src/codec-tab.vala',
      'src/base-codec-tab.vala',
      'src/color-correction-dialog.vala',
      'src/information-tab.vala',
      'src/about-dialog.vala',
      'src/hamburger-menu.vala',
      'src/video-player.vala',
      'src/crop-overlay.vala',
      'src/trim-tab.vala',
      'src/trim-builder.vala',
      'src/trim-runner.vala',
      'src/x264-tab.vala',
      'src/x264-builder.vala',
      'src/vp9-tab.vala',
      'src/vp9-builder.vala',
      'src/codec-presets.vala',
      'src/app-settings.vala',
      'src/settings-dialog.vala',
      'src/subtitle-language-guesser.vala',
      'src/subtitles-tab.vala',
      'src/subtitles-runner.vala',
      'src/ffprobe-utils.vala',
      'src/codec-utils.vala',
      'src/smart-optimizer.vala',
      'src/audio-tab.vala',
      'src/audio-player.vala',
      'src/player-styles.vala',
      'src/audio-builder.vala',
      'src/audio-runner.vala',
      'src/video-file-constants.vala',
      'tests/audio-reorder-state-test.vala',
    ),
    dependencies : dependencies,
    vala_args : ['--define=AUDIO_REORDER_TEST_BUILD'],
    build_by_default : false,
    link_args : ['-lm'],
  )

  test('audio-reorder-state', audio_reorder_state_test)
endif
