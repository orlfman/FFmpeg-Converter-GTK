using Gtk;
using Adw;

public class HamburgerMenu {

    private Gtk.MenuButton menu_button;

    public HamburgerMenu (Gtk.Window parent_window) {
        // Create the menu model
        var menu_model = new GLib.Menu ();
        menu_model.append ("About FFmpeg Converter GTK", "app.about");

        // Create the menu button with the hamburger icon
        menu_button = new Gtk.MenuButton ();
        menu_button.set_icon_name ("open-menu-symbolic");
        menu_button.set_menu_model (menu_model);
        menu_button.set_tooltip_text ("Menu");

        // Register the "about" action on the application
        var about_action = new GLib.SimpleAction ("about", null);
        about_action.activate.connect (() => {
            AboutDialog.show_about (parent_window);
        });

        parent_window.get_application ().add_action (about_action);
    }

    public Gtk.MenuButton get_button () {
        return menu_button;
    }
}
