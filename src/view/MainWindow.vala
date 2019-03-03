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

using GOFI.TXT;

/**
 * The main window of Go For It!.
 */
class GOFI.MainWindow : Gtk.ApplicationWindow {
    /* Various Variables */
    private ListManager list_manager;
    private TaskTimer task_timer;
    private SettingsManager settings;
    private bool use_header_bar;

    /* Various GTK Widgets */
    private Gtk.Grid main_layout;
    private Gtk.HeaderBar header_bar;

    // Stack and pages
    private Gtk.Stack top_stack;
    private SelectionPage selection_page;
    private TaskListPage task_page;
    private Gtk.MenuButton menu_btn;
    private Gtk.ToolButton switch_btn;
    private Gtk.Image switch_img;

    // Application Menu
    private Gtk.Popover menu_popover;
    private Gtk.Box menu_container;
    private Gtk.Box list_menu_container;

    private Gtk.Settings gtk_settings;

    private TodoListInfo? current_list_info;
    private Gtk.Widget? list_menu;

    public const string ACTION_PREFIX = "win";
    public const string ACTION_ABOUT = "about";
    public const string ACTION_CONTRIBUTE = "contribute";
    public const string ACTION_FILTER = "filter";
    public const string ACTION_SETTINGS = "settings";

    private const ActionEntry[] action_entries = {
        { ACTION_ABOUT, show_about_dialog },
#if !NO_CONTRIBUTE_DIALOG
        { ACTION_CONTRIBUTE, show_contribute_dialog },
#endif
        { ACTION_FILTER, toggle_search },
        { ACTION_SETTINGS, show_settings }
    };

    /**
     * Used to determine if a notification should be sent.
     */
    private bool break_previously_active { get; set; default = false; }

    /**
     * The constructor of the MainWindow class.
     */
    public MainWindow (Gtk.Application app_context, ListManager list_manager,
                       TaskTimer task_timer, SettingsManager settings)
    {
        // Pass the applicaiton context via GObject-based construction, because
        // constructor chaining is not possible for Gtk.ApplicationWindow
        Object (application: app_context);
        this.list_manager = list_manager;
        this.task_timer = task_timer;
        this.settings = settings;

        apply_settings ();

        setup_window ();
        setup_actions (app_context);
        setup_menu ();
        setup_widgets ();
        load_css ();
        setup_notifications ();
        // Enable Notifications for the App
        Notify.init (GOFI.APP_NAME);

        load_last ();

        list_manager.list_removed.connect ( (plugin, id) => {
            if (current_list_info != null &&
                current_list_info.plugin_name == plugin &&
                current_list_info.id == id
            ) {
                switch_top_stack (true);
                switch_btn.sensitive = false;
            }
        });
    }

    public override void show_all () {
        base.show_all ();
        if (top_stack.visible_child != task_page) {
            task_page.show_switcher (false);
        }
    }

    private void load_last () {
        var last_loaded = settings.list_last_loaded;
        if (last_loaded != null) {
            var list = list_manager.get_list (last_loaded.id);
            load_list (list);
        } else {
            current_list_info = null;
            list_menu_container.hide ();
        }
    }

    private void apply_settings () {
        this.use_header_bar = settings.use_header_bar;

        gtk_settings = Gtk.Settings.get_default();

        gtk_settings.gtk_application_prefer_dark_theme = settings.use_dark_theme;

        settings.use_dark_theme_changed.connect ( (use_dark_theme) => {
            gtk_settings.gtk_application_prefer_dark_theme = use_dark_theme;
            load_css ();
        });
    }

    public override bool delete_event (Gdk.EventAny event) {
        bool dont_exit = false;

        // Save window state upon deleting the window
        save_win_geometry ();

        if (task_timer.running) {
            this.show.connect (restore_win_geometry);
            hide ();
            dont_exit = true;
        }

        if (dont_exit == false) Notify.uninit ();

        return dont_exit;
    }

    /**
     * Configures the window's properties.
     */
    private void setup_window () {
        this.title = GOFI.APP_NAME;
        this.set_border_width (0);
        restore_win_geometry ();
    }

    /**
     * Initializes GUI elements and configures their look and behavior.
     */
    private void setup_widgets () {
        /* Instantiation of the Widgets */
        main_layout = new Gtk.Grid ();

        /* Widget Settings */
        // Main Layout
        main_layout.orientation = Gtk.Orientation.VERTICAL;
        main_layout.get_style_context ().add_class ("main_layout");

        selection_page = new SelectionPage (list_manager);
        task_page = new TaskListPage (task_timer);

        selection_page.list_chosen.connect (on_list_chosen);

        setup_stack ();
        setup_top_bar ();

        main_layout.add (top_stack);

        // Add main_layout to the window
        this.add (main_layout);
    }

    private void on_list_chosen (TodoListInfo selected_info) {
        if (selected_info == current_list_info) {
            switch_top_stack (false);
            return;
        }
        var list = list_manager.get_list (selected_info.id);
        assert (list != null);
        load_list (list);
        settings.list_last_loaded = ListIdentifier.from_info (selected_info);
        current_list_info = selected_info;
    }

    private void load_list (TxtList list) {
        current_list_info = list.list_info;
        task_page.set_task_list (list);
        switch_btn.sensitive = true;
        switch_top_stack (false);
        if (list_menu != null) {
            list_menu_container.remove (list_menu);
        }
        list_menu = list.get_menu ();
        list_menu_container.pack_start (list_menu);
    }

    private void setup_actions (Gtk.Application app) {
        var actions = new SimpleActionGroup ();
        actions.add_action_entries (action_entries, this);
        insert_action_group (ACTION_PREFIX, actions);
        app.set_accels_for_action (ACTION_PREFIX + "." + ACTION_FILTER, {"<Control>f"});
    }

    private void toggle_search () {
        var visible_page = top_stack.visible_child;
        if (visible_page == task_page) {
            task_page.toggle_filtering ();
        }
    }

    private void setup_stack () {
        top_stack = new Gtk.Stack ();
        top_stack.add (selection_page);
        top_stack.add (task_page);
        top_stack.set_visible_child (selection_page);
    }

    private void setup_top_bar () {
        // Butons and their corresponding images
        var menu_img = GOFI.Utils.load_image_fallback (
            Gtk.IconSize.LARGE_TOOLBAR, "open-menu", "open-menu-symbolic",
            GOFI.ICON_NAME + "-open-menu-fallback");
        menu_btn = new Gtk.MenuButton ();
        menu_btn.hexpand = false;
        menu_btn.image = menu_img;
        menu_btn.tooltip_text = _("Menu");

        menu_popover = new Gtk.Popover (menu_btn);
        menu_popover.add (menu_container);
        menu_btn.popover = menu_popover;

        switch_img = new Gtk.Image.from_icon_name ("go-next", Gtk.IconSize.LARGE_TOOLBAR);
        switch_btn = new Gtk.ToolButton (switch_img, _("_Back"));
        switch_btn.hexpand = false;
        switch_btn.sensitive = false;
        switch_btn.clicked.connect (toggle_top_stack);

        if (use_header_bar){
            add_headerbar ();
        } else {
            add_headerbar_as_toolbar ();
        }
    }

    private void toggle_top_stack () {
        switch_top_stack (top_stack.visible_child == task_page);
    }

    private void switch_top_stack (bool show_select) {
        if (show_select) {
            top_stack.set_visible_child (selection_page);

            var next_icon = GOFI.Utils.get_image_fallback ("go-next-symbolic", "go-next");
            switch_img.set_from_icon_name (next_icon, Gtk.IconSize.LARGE_TOOLBAR);
            settings.list_last_loaded = null;
            task_page.show_switcher (false);
            list_menu_container.hide ();
        } else if (task_page.ready) {
            top_stack.set_visible_child (task_page);
            var prev_icon = GOFI.Utils.get_image_fallback ("go-previous-symbolic", "go-previous");
            switch_img.set_from_icon_name (prev_icon, Gtk.IconSize.LARGE_TOOLBAR);
            if (current_list_info != null) {
                settings.list_last_loaded = ListIdentifier.from_info (current_list_info);
            } else {
                settings.list_last_loaded = null;
            }
            task_page.show_switcher (true);
            list_menu_container.show ();
        }
    }

    /**
     * No other suitable toolbar like widget seems to exist.
     * ToolBar is not suitable due to alignment issues and the "toolbar"
     * styleclass isn't universally supported.
     */
    public void add_headerbar_as_toolbar () {
        header_bar = new Gtk.HeaderBar ();
        header_bar.has_subtitle = false;
        header_bar.get_style_context ().add_class ("toolbar");

        // GTK Header Bar
        header_bar.set_show_close_button (false);

        // Add headerbar Buttons here
        header_bar.pack_start (switch_btn);
        header_bar.set_custom_title (task_page.get_switcher ());
        header_bar.pack_end (menu_btn);

        main_layout.add (header_bar);
    }

    public void add_headerbar () {
        header_bar = new Gtk.HeaderBar ();
        header_bar.has_subtitle = false;

        // GTK Header Bar
        header_bar.set_show_close_button (true);

        // Add headerbar Buttons here
        header_bar.pack_start (switch_btn);
        header_bar.set_custom_title (task_page.get_switcher ());
        header_bar.pack_end (menu_btn);

        this.set_titlebar (header_bar);
    }

    private void setup_menu () {
        /* Initialization */
        menu_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        list_menu_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        var config_item = new Gtk.ModelButton ();

        list_menu_container.pack_end (
            new Gtk.Separator (Gtk.Orientation.HORIZONTAL)
        );

        menu_container.add (list_menu_container);

        config_item.text = _("Settings");
        config_item.action_name = ACTION_PREFIX + "." + ACTION_SETTINGS;
        menu_container.add (config_item);

#if !NO_CONTRIBUTE_DIALOG
        var contribute_item = new Gtk.ModelButton ();
        contribute_item.text = _("Contribute / Donate");
        contribute_item.action_name = ACTION_PREFIX + "." + ACTION_CONTRIBUTE;
        menu_container.add (contribute_item);
#endif

#if SHOW_ABOUT
        var about_item = new Gtk.ModelButton ();
        about_item.text = _("About");
        about_item.action_name = ACTION_PREFIX + "." + ACTION_ABOUT;
        menu_container.add (about_item);
#endif

        menu_container.show_all ();
    }

    private void show_about_dialog () {
        var app = get_application () as Main;
        app.show_about (this);
    }

#if !NO_CONTRIBUTE_DIALOG
    private void show_contribute_dialog () {
        var dialog = new ContributeDialog (this);
        dialog.show ();
    }
#endif

    private void show_settings () {
        var dialog = new SettingsDialog (this, settings);
        dialog.show ();
    }

    /**
     * Configures the emission of notifications when tasks/breaks are over
     */
    private void setup_notifications () {
        task_timer.active_task_changed.connect (task_timer_activated);
        task_timer.timer_almost_over.connect (display_almost_over_notification);
    }

    private void task_timer_activated (TodoTask? task, bool break_active) {
        if (task == null) {
            return;
        }
        if (break_previously_active != break_active) {
            Notify.Notification notification;
            if (break_active) {
                notification = new Notify.Notification (
                    _("Take a Break"),
                    _("Relax and stop thinking about your current task for a while")
                    + " :-)",
                    GOFI.EXEC_NAME);
            } else {
                notification = new Notify.Notification (
                    _("The Break is Over"),
                    _("Your next task is") + ": " + task.description,
                    GOFI.EXEC_NAME);
            }

            try {
                notification.show ();
            } catch (GLib.Error err){
                GLib.stderr.printf (
                    "Error in notify! (break_active notification)\n");
            }
        }
        break_previously_active = break_active;
    }

    private void display_almost_over_notification (DateTime remaining_time) {
        int64 secs = remaining_time.to_unix ();
        Notify.Notification notification = new Notify.Notification (
            _("Prepare for your break"),
            _("You have %s seconds left").printf (secs.to_string ()), GOFI.EXEC_NAME);
        try {
            notification.show ();
        } catch (GLib.Error err){
            GLib.stderr.printf (
                "Error in notify! (remaining_time notification)\n");
        }
    }

    /**
     * Searches the system for a css stylesheet, that corresponds to go-for-it.
     * If it has been found in one of the potential data directories, it gets
     * applied to the application.
     */
    private void load_css () {
        var screen = this.get_screen ();
        var css_provider = new Gtk.CssProvider ();

        string color = settings.use_dark_theme ? "-dark" : "";
        string version = (Gtk.get_minor_version () >= 19) ? "3.20" : "3.10";

        // Pick the stylesheet that is compatible with the user's Gtk version
        string stylesheet = @"go-for-it-$version$color.css";

        var path = Path.build_filename (DATADIR, "style", stylesheet);
        if (FileUtils.test (path, FileTest.EXISTS)) {
            try {
                css_provider.load_from_path (path);
                Gtk.StyleContext.add_provider_for_screen (
                    screen,css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            } catch (Error e) {
                warning ("Cannot load CSS stylesheet: %s", e.message);
            }
        } else {
            warning ("Could not find application stylesheet in %s", path);
        }
    }

    /**
     * Restores the window geometry from settings
     */
    private void restore_win_geometry () {
        if (settings.win_x == -1 || settings.win_y == -1) {
            // Center if no position have been saved yet
            this.set_position (Gtk.WindowPosition.CENTER);
        } else {
            this.move (settings.win_x, settings.win_y);
        }
        this.set_default_size (settings.win_width, settings.win_height);
    }

    /**
     * Persistently store the window geometry
     */
    private void save_win_geometry () {
        int x, y, width, height;
        this.get_position (out x, out y);
        this.get_size (out width, out height);

        // Store values in SettingsManager
        settings.win_x = x;
        settings.win_y = y;
        settings.win_width = width;
        settings.win_height = height;
    }
}
