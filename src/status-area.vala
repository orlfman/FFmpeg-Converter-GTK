using Gtk;
using Adw;

public class StatusArea : Box {
    public Label status_label { get; private set; }
    public ProgressBar progress_bar { get; private set; }

    public StatusArea () {
        Object (orientation: Orientation.VERTICAL, spacing: 12);
        set_margin_top (12);
        set_margin_bottom (12);

        status_label = new Label ("Ready. Select a file and click Convert.");
        status_label.set_wrap (true);
        status_label.set_justify (Justification.CENTER);
        append (status_label);

        progress_bar = new ProgressBar ();
        progress_bar.set_show_text (true);
        progress_bar.set_text ("Waiting...");
        progress_bar.set_visible (false);
        append (progress_bar);
    }

    // Helper methods for Converter
    public void set_status (string text) {
        Idle.add (() => {
            status_label.set_text (text);
            return Source.REMOVE;
        });
    }

    public void start_progress () {
        Idle.add (() => {
            progress_bar.set_visible (true);
            progress_bar.pulse ();
            return Source.REMOVE;
        });
    }

    public void stop_progress () {
        Idle.add (() => {
            progress_bar.set_visible (false);
            return Source.REMOVE;
        });
    }
}
