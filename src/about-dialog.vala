using Gtk;
using Adw;

namespace AboutDialog {

    public void show_about (Gtk.Window parent) {
        var about = new Adw.AboutDialog ();

        about.set_application_name ("FFmpeg Converter GTK");
        about.set_version ("1.1");
        about.set_application_icon ("ffmpeg-converter-gtk");
        about.set_developer_name ("orlfman");
        about.set_website ("https://github.com/orlfman/FFmpeg-Converter-GTK");
        about.set_issue_url ("https://github.com/orlfman/FFmpeg-Converter-GTK/issues");
        about.add_legal_section ("The Unlicense", "This is free and unencumbered software released into the public domain.\nFor more information, please refer to https://unlicense.org", Gtk.License.CUSTOM, null);
        about.set_comments ("A GTK4/libadwaita frontend for FFmpeg video conversion.");
        about.set_developers ({ "orlfman https://github.com/orlfman" });

        about.present (parent);
    }
}
