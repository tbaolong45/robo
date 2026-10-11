// Exposes the focused window to robo: org.robo.Focus.Current() -> (app_id, title).
// GNOME 50 denies org.gnome.Shell.Introspect to ordinary clients, so robo asks this instead.
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const NAME = 'org.robo.Focus';
const PATH = '/org/robo/Focus';
const IFACE = `<node><interface name="${NAME}"><method name="Current">
  <arg type="s" direction="out" name="app_id"/><arg type="s" direction="out" name="title"/>
</method></interface></node>`;

function current() {
    const win = global.display.focus_window;
    if (!win)
        return ['', ''];
    const app = Shell.WindowTracker.get_default().get_window_app(win);
    const tracked = app?.get_id()?.replace(/\.desktop$/, '');
    // WindowTracker invents "window:<n>" for windows it can't match to an installed app.
    const id = (tracked && !tracked.startsWith('window:') ? tracked : '') ||
        win.get_gtk_application_id() || win.get_wm_class() || tracked || '';
    return [id, win.get_title() ?? ''];
}

export default class RoboFocusExtension extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, {Current: current});
        this._dbus.export(Gio.DBus.session, PATH);
        this._owner = Gio.bus_own_name_on_connection(Gio.DBus.session, NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        Gio.bus_unown_name(this._owner);
        this._dbus.unexport();
        this._dbus = null;
        this._owner = 0;
    }
}
