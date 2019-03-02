/* Copyright 2014-2019 Go For It! developers
*
* This file is part of Go For It!.
*
* Go For It! is free software: you can redistribute it
* and/or modify it under the terms of version 3 of the
* GNU General Public License as published by the Free Software Foundation.
*
* Go For It! is distributed in the hope that it will be
* useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
* Public License for more details.
*
* You should have received a copy of the GNU General Public License along
* with Go For It!. If not, see http://www.gnu.org/licenses/.
*/

/**
 * A class that handles access to settings in a transparent manner.
 * Its main motivation is the option of easily replacing Glib.KeyFile with
 * another settings storage mechanism in the future.
 */
class GOFI.TXT.TxtListManager {
    private KeyFile key_file;
    private string list_file;
    private string config_dir;

    private HashTable<string, ListSettings> list_table;

    public bool first_run {
        public get;
        private set;
    }

    public signal void lists_added (List<TodoListInfo> new_lists);
    public signal void lists_removed (List<string> removed);

    /**
     * Constructs a SettingsManager object from a configuration file.
     * Reads the corresponding file and creates it, if necessary.
     */
    public TxtListManager (string config_dir) {
        this.config_dir = config_dir;
        this.list_file= Path.build_filename (
            config_dir, "lists"
        );
        // Instantiate the key_file object
        key_file = new KeyFile ();
        first_run = true;

        if (!FileUtils.test (list_file, FileTest.EXISTS)) {
            int dir_exists = DirUtils.create_with_parents (
                config_dir, 0775
            );
            if (dir_exists != 0) {
                error (_("Couldn't create directory: %s"), config_dir);
            }
        } else {
            // If it does exist, read existing values
            first_run = false;
            try {
                key_file.load_from_file (list_file,
                   KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);
            } catch (Error e) {
                stderr.printf ("Reading %s failed", list_file);
                error ("%s", e.message);
            }
        }

        create_settings_instances ();
    }

    public TxtListEditDialog get_creation_dialog (Gtk.Window? parent) {
        var dialog = new TxtListEditDialog (parent, this);
        dialog.add_list_clicked.connect ( (settings) => {
            add_new_from_settings (settings);
            dialog.destroy ();
        });
        return dialog;
    }

    /**
     * Checks if the path is used by another TxtList
     * The path must be absolute
     */
    public bool location_available (ListSettings changed) {
        var path = changed.todo_txt_location;
        foreach (ListSettings list in list_table.get_values ()) {
            if (list.todo_txt_location == path && list.id != changed.id) {
                return false;
            }
        }
        return true;
    }

    public TxtList? get_list (string id) {
        return new TxtList (list_table[id]);
    }

    public TodoListInfo? get_list_info (string id) {
        return list_table[id];
    }

    public void delete_list (string id, Gtk.Window? window) {
        assert (list_table.contains (id));

        list_table.remove (id);
        try {
            key_file.remove_group ("list" + id);
        } catch (Error e) {
            warning ("List could not be fully removed: %s", e.message);
        }

        var removed = new List<string> ();
        removed.prepend (id);

        lists_removed (removed);
    }

    public void edit_list (string id, Gtk.Window? window) {
        var info = list_table[id];
        assert (info != null);

        var dialog = new TxtListEditDialog (window, this, info.copy ());
        dialog.add_list_clicked.connect ( (settings) => {
            if (settings.todo_txt_location != info.todo_txt_location) {
                var dir = File.new_for_path (settings.todo_txt_location);
                if (!dir.query_exists ()) {
                    DirUtils.create_with_parents (dir.get_path (), 0700);
                }
                var todo_txt = dir.get_child ("todo.txt");
                var done_txt = dir.get_child ("done.txt");
                if (todo_txt.query_exists () || done_txt.query_exists ()) {
                    var confirm_dialog = create_conflict_dialog (dialog);
                    confirm_dialog.response.connect ((s, response) => {
                        switch (response) {
                            case Gtk.ResponseType.ACCEPT:
                                stdout.printf ("Moving files to %s\n", settings.todo_txt_location);
                                move_files (todo_txt, done_txt, info.todo_txt_location);
                                info.apply (settings);
                                confirm_dialog.destroy ();
                                dialog.destroy ();
                                break;
                            case Gtk.ResponseType.REJECT:
                                info.apply (settings);
                                confirm_dialog.destroy ();
                                dialog.destroy ();
                                break;
                            default:
                                confirm_dialog.destroy ();
                                break;
                        }
                    });
                    confirm_dialog.show ();
                    return;
                }
                move_files (todo_txt, done_txt, info.todo_txt_location);
            }
            info.apply (settings);
            dialog.destroy ();
        });
        dialog.show_all ();
    }

    private void move_files (File todo_txt, File done_txt, string orig) {
        var dir = File.new_for_path (orig);
        var orig_todo_txt = dir.get_child ("todo.txt");
        var orig_done_txt = dir.get_child ("done.txt");

        try {
            if (orig_todo_txt.query_exists ()) {
                orig_todo_txt.move (todo_txt, FileCopyFlags.OVERWRITE | FileCopyFlags.BACKUP);
            }
            if (orig_done_txt.query_exists ()) {
                orig_done_txt.move (done_txt, FileCopyFlags.OVERWRITE | FileCopyFlags.BACKUP);
            }
        } catch (Error e) {
            show_error_dialog (
                _("An error was encountered while moving a file!")
                +
                "\n" + _("Error information: ") + @"\"$(e.message)\""
            );
        }
    }

    private void show_error_dialog (string msg) {
        var error_dialog = new Gtk.MessageDialog (
            null,
            Gtk.DialogFlags.MODAL,
            Gtk.MessageType.ERROR,
            Gtk.ButtonsType.CLOSE,
            msg
        );
        error_dialog.show ();
    }

    private Gtk.Dialog create_conflict_dialog (Gtk.Window? window) {
        var confirm_dialog = new Gtk.MessageDialog (
            window,
            Gtk.DialogFlags.MODAL,
            Gtk.MessageType.QUESTION,
            Gtk.ButtonsType.NONE,
            _("Todo.txt files were found in the destination directory.")
            +
            "\n"
            +
            _("What should be done with these files?")
        );
        confirm_dialog.add_button (_("Keep old"), Gtk.ResponseType.REJECT);
        var overwrite_but = confirm_dialog.add_button (
            _("Overwrite"), Gtk.ResponseType.ACCEPT
        );
        confirm_dialog.add_button (_("Cancel"), Gtk.ResponseType.CANCEL);
        overwrite_but.get_style_context ().add_class ("destructive-action");
        return confirm_dialog;
    }

    public List<TodoListInfo> get_list_infos () {
        return list_table.get_values ();
    }

    private void create_settings_instances () {
        list_table = new HashTable<string, ListSettings> (
            ((key) => {return (uint) long.parse (key);}), str_equal
        );

        foreach (string group in key_file.get_groups ()) {
            if (group.has_prefix ("list")) {
                var list_id = group.offset (4);
                if (list_id == "") {
                    warning ("Invalid list id stored in %s: '%s'", list_file, group);
                    continue;
                }
                list_table[list_id] = create_settings_instance (list_id);
            }
        }
    }

    private ListSettings create_settings_instance (string list_id) {
        var list_settings = new ListSettings (
            list_id,
            get_name (list_id),
            get_todo_txt_location (list_id)
        );

        list_settings.task_duration = get_task_duration (list_id);
        list_settings.break_duration = get_break_duration (list_id);
        list_settings.reminder_time = get_reminder_time (list_id);
        connect_settings_signals (list_settings);

        return list_settings;
    }

    public bool has_id (string id) {
        return list_table.contains (id);
    }

    public string get_new_id (string name) {
        uint id = str_hash (name);
        string id_str = id.to_string ();
        while (has_id (id_str)) {
            if (id < uint.MAX) {
                id++;
            } else {
                id = 0;
            }
            id_str = id.to_string ();
        }
        return id_str;
    }

    /**
     * Availability of the location must have been checked in advance
     */
    public void add_new (string name, string txt_location) {
        string id = get_new_id (name);
        var list_settings = new ListSettings (
            id,
            name,
            txt_location
        );
        add_listsettings (list_settings);
    }

    public void add_new_from_settings (ListSettings settings) {
        string id = get_new_id (settings.name);
        var list_settings = new ListSettings (
            id,
            settings.name,
            settings.todo_txt_location
        );
        add_listsettings (list_settings);
    }

    private void add_listsettings (ListSettings settings) {
        stdout.printf ("added: %s (%s)\n", settings.name, settings.id);
        connect_settings_signals (settings);
        list_table[settings.id] = settings;

        var added = new List<TodoListInfo> ();
        added.prepend (settings);

        lists_added (added);
        save_listsettings (settings);
    }

    private void save_listsettings (ListSettings list) {
        set_name (list.id, list.name);
        set_todo_txt_location (list.id, list.todo_txt_location);
        set_task_duration (list.id, list.task_duration);
        set_break_duration (list.id, list.break_duration);
        set_reminder_time (list.id, list.reminder_time);
    }

    private void connect_settings_signals (ListSettings list_settings) {
        list_settings.notify.connect ((object, pspec) => {
            var list = (ListSettings) object;
            switch (pspec.name) {
                case "name":
                    set_name (list.id, list.name);
                    break;
                case "todo-txt-location":
                    set_todo_txt_location (list.id, list.todo_txt_location);
                    break;
                case "task-duration":
                    set_task_duration (list.id, list.task_duration);
                    break;
                case "break-duration":
                    set_break_duration (list.id, list.break_duration);
                    break;
                case "reminder-time":
                    set_reminder_time (list.id, list.reminder_time);
                    break;
            }
        });
    }

    public string get_todo_txt_location (string list_id) {
        return get_value (list_id, "location");
    }
    public void set_todo_txt_location (string list_id, string value) {
        set_value (list_id, "location", value);
    }

    public string get_name (string list_id) {
        return get_value (list_id, "name");
    }
    public void set_name (string list_id, string value) {
        set_value (list_id, "name", value);
    }

    /*---Overrides------------------------------------------------------------*/
    public int get_task_duration (string list_id) {
        var duration = get_value (list_id, "task_duration", "1500");
        return int.parse (duration);
    }
    public void set_task_duration (string list_id, int value) {
        set_value (list_id, "task_duration", value.to_string ());
    }

    public int get_break_duration (string list_id) {
        var duration = get_value (list_id, "break_duration", "300");
        return int.parse (duration);
    }
    public void set_break_duration (string list_id, int value) {
        set_value (list_id, "break_duration", value.to_string ());
    }

    public int get_reminder_time (string list_id) {
        var time = get_value (list_id, "reminder_time", "60");
        return int.parse (time);
    }
    public void set_reminder_time (string list_id, int value) {
        set_value (list_id, "reminder_time", value.to_string ());
    }

    /**
     * Provides read access to a setting, given a certain group and key.
     * Public access is granted via the SettingsManager's attributes, so this
     * function has been declared private
     */
    private string get_value (string list_id, string key, string default = "") {
        var group = "list" + list_id;
        try {
            // use key_file, if it has been assigned
            if (key_file != null
                && key_file.has_group (group)
                && key_file.has_key (group, key)) {
                    return key_file.get_value (group, key);
            } else {
                return default;
            }
        } catch (Error e) {
                error ("An error occured while reading the setting"
                    +" %s.%s: %s", group, key, e.message);
        }
    }

    /**
     * Provides write access to a setting, given a certain group key and value.
     * Public access is granted via the SettingsManager's attributes, so this
     * function has been declared private
     */
    private void set_value (string list_id, string key, string value) {
        var group = "list" + list_id;
        if (key_file != null) {
            try {
                key_file.set_value (group, key, value);
                write_key_file ();
            } catch (Error e) {
                error ("An error occured while writing the setting"
                    +" %s.%s to %s: %s", group, key, value, e.message);
            }
        }
    }

    private void write_key_file () throws Error {
        int dir_exists = DirUtils.create_with_parents (config_dir, 0775);
        if (dir_exists != 0) {
            error (_("Couldn't create directory: %s"), config_dir);
        }
        GLib.FileUtils.set_contents (list_file, key_file.to_data ());
    }
}