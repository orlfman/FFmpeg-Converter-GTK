using Gtk;
using Adw;

public class ConsoleTab : Box {
    public TextView console_view { get; private set; }
    private Button clear_button;
    private Entry command_entry;

    public ConsoleTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 12);
        set_margin_top (12);
        set_margin_bottom (12);
        set_margin_start (12);
        set_margin_end (12);

        // Top bar: Command display + Clear button
        var top_bar = new Box (Orientation.HORIZONTAL, 12);
        top_bar.set_hexpand (true);

        // Read-only command display (left side)
        command_entry = new Entry ();
        command_entry.set_editable (false);
        command_entry.set_placeholder_text ("FFmpeg command will appear here...");
        command_entry.set_hexpand (true);
        top_bar.append (command_entry);

        // Clear button (right side)
        clear_button = new Button.with_label ("🗑️ Clear Console");
        top_bar.append (clear_button);

        append (top_bar);

        // Console text view
        console_view = new TextView ();
        console_view.editable = false;
        console_view.cursor_visible = false;
        console_view.monospace = true;
        console_view.wrap_mode = WrapMode.WORD_CHAR;

        var scrolled = new ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_child (console_view);
        append (scrolled);

        // Connect clear button
        clear_button.clicked.connect (() => {
            console_view.buffer.text = "";
            command_entry.set_text ("");
        });
    }

    public void set_command (string full_command) {
        Idle.add (() => {
            command_entry.set_text (full_command);
            return Source.REMOVE;
        });
    }

    public void add_line (string line) {
        Idle.add (() => {
            var buffer = console_view.buffer;
            TextIter end;
            buffer.get_end_iter (out end);
            buffer.insert (ref end, line + "\n", -1);
            return Source.REMOVE;
        });
    }
}
