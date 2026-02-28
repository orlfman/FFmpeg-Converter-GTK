project('ffmpeg-converter-gtk',
  ['vala', 'c'],
  version : '0.1.0',
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
]

sources = files(
  'src/main.vala',
  'src/svt-av1-tab.vala',
  'src/general-tab.vala',
  'src/converter.vala',
  'src/file-pickers.vala',
  'src/status-area.vala',
  'src/console-tab.vala',
  'src/filter-builder.vala',
  'src/svt-av1-builder.vala',
  'src/audio-settings.vala',
  'src/conversion-runner.vala',
  'src/codec-builder.vala',
  'src/x265-tab.vala',
  'src/x265-builder.vala',
  'src/codec-tab.vala',
  'src/color-correction-dialog.vala',
  'src/information-tab.vala',
  'src/about-dialog.vala',
  'src/hamburger-menu.vala',
  'src/video-player.vala',
  'src/trim-tab.vala',
  'src/trim-builder.vala',
  'src/trim-runner.vala',
)

executable('ffmpeg-converter-gtk',
  sources,
  dependencies : dependencies,
  link_args : ['-lm'],
  install : true,
  install_dir : get_option('bindir')
)
