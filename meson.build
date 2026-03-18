project('ffmpeg-converter-gtk',
  ['vala', 'c'],
  version : '1.5.0',
  meson_version : '>= 0.62.0',
  default_options : [
    'warning_level=3',
    'buildtype=debugoptimized'
  ]
)
gnome = import('gnome')
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
  'src/smart-optimizer.vala'
)
executable('ffmpeg-converter-gtk',
  sources,
  dependencies : dependencies,
  link_args : ['-lm'],
  install : true,
  install_dir : get_option('bindir')
)

fs = import('fs')
if fs.exists('tests/subtitle-language-guesser-test.vala')
  subtitle_language_guesser_test = executable(
    'subtitle-language-guesser-test',
    files(
      'src/subtitle-language-guesser.vala',
      'tests/subtitle-language-guesser-test.vala',
    ),
    vala_args : ['--define=SUBTITLE_LANGUAGE_GUESSER_TEST_BUILD'],
    dependencies : [
      dependency('glib-2.0'),
      dependency('gio-2.0'),
      dependency('json-glib-1.0'),
    ],
  )

  test('subtitle-language-guesser', subtitle_language_guesser_test)
endif
