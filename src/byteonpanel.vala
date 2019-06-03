/**
 *  Byte On Panel: Display bandwidth usage on desktop panel.
 *
 *  Copyright (c) 2011-2013 Mozbugbox <mozbugbox@yahoo.com.au>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */
using Gtk;

const double fdelta = 1E-9;
const uint MAX_SLOT = 30;
const int MIN_STATUS_ICON_SIZE = 16;
const string SYS_NET_PATH = "/sys/class/net";

public struct ByteStat {
    public double time_stamp;

    public uint64 rx_total;
    public double rx_speed;

    public uint64 tx_total;
    public double tx_speed;

    public double total_speed;
}

string humanize_number(double num,
                       float step=1024.0f,
                       string unit_string="B") {
    string[] ends = {"", "K","M","G","T","P","E","Z","Y"};
    string the_end = ends[ends.length-1];
    foreach(var i in ends) {
        if (num < step) {
            the_end = i;
            break;
        }
        num /= step;
    }
    return "%.2f%s%s".printf(num, the_end, unit_string);
}

public class IFace: GLib.Object {

    private string iface_path;
    private string rx_path;
    private string tx_path;
    private string operstate_path;
    private GLib.TimeVal tval;

    public string iface_id;
    public uint maxlen = MAX_SLOT;
    public GLib.Queue<ByteStat?> flow_queue;

    public IFace(string if_name) {
        iface_id = if_name;
        iface_path = Path.build_filename(SYS_NET_PATH, iface_id);
        rx_path = Path.build_filename(iface_path, "statistics", "rx_bytes");
        tx_path = Path.build_filename(iface_path, "statistics", "tx_bytes");
        operstate_path = Path.build_filename(iface_path, "operstate");

        flow_queue = new GLib.Queue<ByteStat?>();
        tval = GLib.TimeVal();
    }

    public bool isup {
        get {
            string text;
            try {
                FileUtils.get_contents(operstate_path, out text);
            } catch(FileError e) {
                stderr.printf("Error: %s\n", e.message);
                return false;
            }
            return (text.strip().down() == "up");
        }
    }

    public void update() {
        double time_stamp;
        double rx_rate, tx_rate;
        rx_rate = tx_rate = 0;
        uint64 rx, tx;

        try {
            // FIXME: 32 is enough? greater than uint64
            uint8[] rx_buf = new uint8[64];
            uint8[] tx_buf = new uint8[64];
            size_t rlen;

            var fd = File.new_for_path(rx_path);
            var rx_stream = fd.read();
            fd = File.new_for_path(tx_path);
            var tx_stream = fd.read();

            tval.get_current_time();
            rx_stream.read_all(rx_buf, out rlen);
            tx_stream.read_all(tx_buf, out rlen);
            rx_stream.close();
            tx_stream.close();

            rx = uint64.parse((string)rx_buf);
            tx = uint64.parse((string)tx_buf);

        } catch(Error e) {
            stderr.printf("Error: %s\n", e.message);
            return;
        }

        time_stamp = tval.tv_sec + tval.tv_usec/1000000.0; 
        var last_stat = flow_queue.peek_tail();
        if (flow_queue.length > 1) {
            double laps = time_stamp - last_stat.time_stamp;
            if (laps == 0.0) {
                rx_rate = 0.0;
                tx_rate = 0.0;
            } else {
                rx_rate = (rx - last_stat.rx_total) / laps;
                tx_rate = (tx - last_stat.tx_total) / laps;
            }
        }

        ByteStat item = {time_stamp, rx, rx_rate, tx, tx_rate,
                         rx_rate + tx_rate};
        flow_queue.push_tail(item);
        // Limit size to maxlen
        while (flow_queue.length> maxlen) {
            flow_queue.pop_head();
        }
    }
}

public class StatusIconIF: GLib.Object {
    private Application app;
    private Cairo.Context? ctx = null;
    private Cairo.ImageSurface surface;
    private double scale = -1.0;
    private Gtk.StatusIcon statusicon;
    private Gtk.Menu menu;
    private uint update_id;
    private uint update_scale_id;
    private int margin = 1;

    public IFace iface;
    public float[] rx_color = { 0.0f, 1.0f, 0.0f };
    public float[] tx_color = { 1.0f, 1.0f, 0.0f };
    public float portion = 0.8f; // rate height against icon height
    public float portion_low = 0.3f;
    public float rate_low = 1024.0f;
    public uint update_timeout = 1000;
    public uint update_scale_timeout;


    public StatusIconIF(Application app_obj, IFace iface_obj) {
        app = app_obj;
        iface = iface_obj;
        update_scale_timeout = MAX_SLOT * update_timeout;
        setup_icon();
    }

    private void setup_icon() {
        statusicon = new Gtk.StatusIcon();
        statusicon.set_visible(true);
        statusicon.set_title(Config.PACKAGE_NAME);
        statusicon.size_changed.connect(on_status_icon_size_changed);
        setup_menu();
        if (statusicon.is_embedded()) {
            var size = statusicon.get_size();
            var hsize = size;
            if (size >= MIN_STATUS_ICON_SIZE)
                hsize = size - margin * 2;
            surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, hsize);
            ctx = new Cairo.Context(surface);
        }
    }

    private bool on_status_icon_size_changed(StatusIcon sicon, int size) {
        if (statusicon.is_embedded()) {
            var hsize = size;
            if (size >= MIN_STATUS_ICON_SIZE)
                hsize = size - margin * 2;
            surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, size, hsize);
            ctx = new Cairo.Context(surface);
        }
        return true;
    }

    private void on_popup_menu(uint button, uint atime) {
        menu.popup(null, null, null, button, atime);
    }

    private void setup_menu() {
        // (name, stock_id, label, accelerator, tooltip, callback)
        /* FIXME: vala cannot handle this!!
        ActionEntry[] action_entries = {
            ActionEntry() {name="About", stock_id=Gtk.Stock.ABOUT,
                callback= app.on_about_dialog_show },
            ActionEntry() {name="Quit", stock_id=Gtk.Stock.QUIT,
                callback= on_quit}
        };
        */

        const string ui_info = """
            <ui>
                <popup name="Popup">
                    <menuitem action="About"/>
                    <separator/>
                    <menuitem action="Quit"/>
                </popup>
            </ui>
        """;
        var actions = new Gtk.ActionGroup("StatusIconPopup");
        //actions.add_actions(action_entries, null);
        Gtk.Action action;
        action = new Gtk.Action("About", null, null, Gtk.Stock.ABOUT);
        action.activate.connect(app.on_about_dialog_show);
        actions.add_action(action);

        action = new Gtk.Action("Quit", null, null, Gtk.Stock.QUIT);
        action.activate.connect(on_quit);
        actions.add_action(action);

        var ui = new Gtk.UIManager();
        ui.insert_action_group(actions, 0);
        try {
            ui.add_ui_from_string(ui_info, -1);
        } catch(Error e) {
            stderr.printf("Error: %s\n", e.message);
            return;
        }
        menu = ui.get_widget("/Popup") as Gtk.Menu;
        statusicon.popup_menu.connect(on_popup_menu);
        return;
    }

    private string make_tooltip() {
        double rx_av, tx_av;
        rx_av = tx_av = 0.0;
        var last_stat = iface.flow_queue.peek_tail();
        var first_stat = iface.flow_queue.peek_head();
        if(iface.flow_queue.length> 1) {
            rx_av = (last_stat.rx_total - first_stat.rx_total)/(last_stat.time_stamp - first_stat.time_stamp);
            tx_av = (last_stat.tx_total - first_stat.tx_total)/(last_stat.time_stamp - first_stat.time_stamp);
        }
        var rx_now = humanize_number(last_stat.rx_speed);
        var tx_now = humanize_number(last_stat.tx_speed);
        var rx_av_text = humanize_number(rx_av);
        var tx_av_text = humanize_number(tx_av);
        var txt = """Interface: %s
In/Out(current): %s/%s
In/Out(average): %s/%s""".printf(iface.iface_id, rx_now, tx_now, 
            rx_av_text, tx_av_text);
        
        return txt;
    }

    private double max_total_speed(GLib.Queue<ByteStat?> somed) {
        double a = double.MIN;
        for(var i = 0; i < somed.length; i++) {
            var b = somed.peek_nth(i);
            if (b.total_speed > a)
                a = b.total_speed;
        }
        return a;
    }

    public bool update_scale() {
        int height = surface.get_height();
        double total = max_total_speed(iface.flow_queue);
        float port = portion;

        // Don't display slow bandwidth too height
        if (total < rate_low) {
            port = portion_low;
        }
        if (total > fdelta) { /* don't compare double to 0 */
            double lscale = height * port / total;
            
            if ((scale < -fdelta ) ||
                (scale > fdelta && Math.fabs(scale - lscale)/scale > 0.3) ||
                (height < scale * total)) {
                scale = lscale;
            }
        }
        return true;
    }

    private struct TransSpeed {
        public double[] rx_list;
        public double[] tx_list;
    }

    private TransSpeed get_speed(double max_speed) {
        double[] rx_list = new double[iface.flow_queue.length];
        double[] tx_list = new double[iface.flow_queue.length];

        if (scale < -fdelta) {
            update_scale();
        }
        double lscale;
        if (scale < -fdelta) {
            lscale = 1.0;
        } else {
            lscale = scale;
        }

        for(var i = 0; i < iface.flow_queue.length; i++) {
            var statn = iface.flow_queue.peek_nth(i);
            double rspeed = statn.rx_speed*lscale;
            double tspeed = statn.tx_speed*lscale;
            if((rspeed + tspeed) > max_speed) {
                update_scale();
                return get_speed(max_speed);
            } else {
                rx_list[i] = rspeed;
                tx_list[i] = tspeed;
            }
        }
        TransSpeed ret = TransSpeed(){rx_list=rx_list, tx_list=tx_list};
        return ret;
    }

    public bool update() {
        if (ctx == null) return true;

        iface.update();
        var tooltxt = make_tooltip();
        statusicon.set_tooltip_text(tooltxt);

        var graph_width = surface.get_width();
        var graph_height = surface.get_height();
        
        TransSpeed ls = get_speed(graph_height);
        double[] rx_list = ls.rx_list;
        double[] tx_list = ls.tx_list;
        var slow_width = (float)graph_width/iface.maxlen;
        var xoffset = iface.maxlen - rx_list.length;

        ctx.paint();
        ctx.save();
        ctx.set_source_rgb(rx_color[0], rx_color[1], rx_color[2]);
        ctx.new_path();
        for(var i = 0; i < rx_list.length; i++) {
            var speed = rx_list[i];
            // (top, left) = (0, 0); x, y = topleft -> southeast
            ctx.rectangle(slow_width*(i+xoffset),
                graph_height - speed, slow_width, speed);
        }
        ctx.fill();

        ctx.set_source_rgb(tx_color[0], tx_color[1], tx_color[2]);
        ctx.new_path();
        for(var i = 0; i < tx_list.length; i++) {
            var speed = tx_list[i];
            // (top, left) = (0, 0); x, y = topleft -> southeast
            ctx.rectangle(slow_width*(i+xoffset),
                0, slow_width, speed);
        }
        ctx.fill();
        ctx.restore();
        Gdk.Pixbuf pixbuf = GdkOverrides.pixbuf_get_from_surface(surface, 0, 0,
                        graph_width, graph_height);
        statusicon.set_from_pixbuf(pixbuf);
        // keep timeout going by return true.
        return true;
    }

    public void start_timers() {
        update_id = Timeout.add(update_timeout, update);
        update_scale_id = Timeout.add(update_scale_timeout,
                            update_scale);
    }
    public void on_quit(Gtk.Action act) {
        app.quit();
    }

    public void on_destroy() {
        Source.remove(update_id);
        Source.remove(update_scale_id);
    }

}
public class Application: GLib.Object {
    private GLib.Tree<string, StatusIconIF> iface_map;
    private uint iface_update_timeout = 5;

    private Application() {
        iface_map = new GLib.Tree<string, StatusIconIF>.full(
            (a, b) => {
                return strcmp(a, b);
            },
            g_free, g_object_unref);

    }
    private bool update_iface() {
        try {
            var root = File.new_for_path(SYS_NET_PATH);

            var root_enum = root.enumerate_children(
                                FileAttribute.STANDARD_NAME, 0);
            FileInfo file_info;
            while((file_info = root_enum.next_file()) != null) {
                var fid = file_info.get_name();
                if (fid != "lo" && (iface_map.lookup(fid) == null)) {
                    var iface = new IFace(fid);
                    if(iface.isup) {
                        var v = new StatusIconIF(this, iface);
                        v.start_timers();
                        v.update();
                        iface_map.insert(fid, v);
                    }
                }
            }
        } catch(Error e) {
            stderr.printf("Error: %s\n", e.message);
        }
        // Update status
        /* Cannot delete keys while looping a map. */
        string[] key2remove = {};
        iface_map.foreach((k, v) => {
                var v1 = v as StatusIconIF;
                if(!v1.iface.isup) {
                    key2remove += (string) k;
                }
#if VALA_0_18
                return false;
#else
                return 0;
#endif
            });
        foreach(var k in key2remove) {
            iface_map.lookup(k).on_destroy();
            iface_map.remove(k);
        }
        return true;
    }

    private ulong about_response_id;
    public void on_about_dialog_show(Gtk.Action act) {
        var ad = new Gtk.AboutDialog();
        about_response_id = ad.response.connect((a, b) => {
            a.disconnect(about_response_id);
            a.destroy();
        });
        ad.set_program_name(Config.PACKAGE_NAME);
        ad.set_version(Config.HGVERSION);
        ad.set_copyright("Mozbugbox 2011-2013");
        ad.set_license_type(Gtk.License.GPL_3_0);
        ad.set_website(Config.PACKAGE_URL);
        ad.set_website_label("Byte On Panel Wiki");
        string[] authors = { "Mozbugbox" }; // cannot make const string[]?
        ad.set_authors(authors);
        ad.present();
    }

    public void start() {
        update_iface();
        Timeout.add_seconds(iface_update_timeout, update_iface);
        Gtk.main();
    }
    public void quit() {
        Gtk.main_quit();
    }

    public static int main(string[] args) {
        Gtk.init(ref args);
        var app = new Application();
        app.start();
        return 0;
    }
}
