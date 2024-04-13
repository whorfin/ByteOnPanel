#!/usr/bin/python3
# vim:fileencoding=utf-8:sw=4:et
"""
    Byte On Panel: Display bandwidth usage on desktop panel.

    Copyright (c) 2011-2013 Mozbugbox <mozbugbox@yahoo.com.au>

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2, or (at your option)
    any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
"""
import os
import time
from gi.repository import Gtk, GObject, Gdk
import cairo

__version__ = "Version 0.1"

MAX_SLOT = 30
sys_net_path = "/sys/class/net"

class SizedList(list):
    def __init__(self, maxlen=0):
        self.maxlen = maxlen
    def append(self, data):
        list.append(self, data)
        ll = len(self)
        if ll == self.maxlen + 1:
            self.pop(0)
        elif ll > self.maxlen:
            del self[:ll - self.maxlen]

def humanize_number(num, step=1024, unit_string='B'):
    for x in ['','K','M','G','T','P','E','Z','Y']:
        if num < step:
            break
        num /= step
    return "{0:.2f}{1}{2}".format(num, x, unit_string)

def hide_window(w, *args):
    """Hide a gtk window."""
    w.hide()
    return True

class IFace:
    """Data for a network interface."""
    def __init__(self, ifid):
        self.ifid = ifid
        self.maxlen = MAX_SLOT
        ifpath = os.path.join(sys_net_path, ifid)
        if os.path.exists(ifpath):
            self.ifpath = ifpath
        else:
            raise AttributeError(ifpath)
        self.rx_path = os.path.join(ifpath, "statistics", "rx_bytes")
        self.tx_path = os.path.join(ifpath, "statistics", "tx_bytes")
        self.rx_queue = SizedList(maxlen=self.maxlen)
        self.tx_queue = SizedList(maxlen=self.maxlen)
        self.total_rate_queue = SizedList(maxlen=self.maxlen)

    def isup(self):
        fd = open(os.path.join(self.ifpath, "operstate"))
        text = fd.read().strip()
        fd.close()
        ret = text.lower() == "up"
        return ret

    def update(self):
        rx_q = self.rx_queue
        tx_q = self.tx_queue

        fd = open(self.rx_path)
        rx = fd.read()
        fd.close()
        rx_stamp = time.time()
        fd = open(self.tx_path)
        tx = fd.read()
        fd.close()
        tx_stamp = time.time()
        rx = int(rx)
        tx = int(tx)

        try:
            rx_rate = (rx - rx_q[-1][1])/(rx_stamp - rx_q[-1][0])
            tx_rate = (tx - tx_q[-1][1])/(tx_stamp - tx_q[-1][0])
        except IndexError:
            rx_rate = 0
            tx_rate = 0
        rx_q.append((rx_stamp, rx, rx_rate))
        tx_q.append((tx_stamp, tx, tx_rate))
        self.total_rate_queue.append(rx_rate + tx_rate)

class StatusBarIF:
    """A status icon that display a network interface data flow."""
    def __init__(self, app, iface):
        self.app = app
        self.iface = iface
        self.ctx = None
        self.scale = 0
        self.rx_color = (0, 1.0, 0)
        self.tx_color = (1.0, 1.0, 0.0)
        self.portion = 0.8    # rate height against icon height.
        self.portion_low = 0.3
        self.rate_low = 1024  # total speed threshold for using portion_low
        self.update_timeout = 1000
        self.update_scale_timeout = MAX_SLOT * self.update_timeout

        self.setup_icon()

    def setup_icon(self):
        """UI Setup."""
        statusicon = Gtk.StatusIcon()
        statusicon.set_visible(True)
        size = statusicon.get_size() # A single value.
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32,
                size, size)
        ctx = cairo.Context(surface)
        self.menu = self.setup_menu()

        statusicon.connect("popup-menu", self.on_popup_menu)
        self.ctx = ctx
        self.statusicon = statusicon

    def on_popup_menu(self, statusicon, but, atime, *dummy):
        self.menu.popup(None, None, None, None, but, atime)

    def setup_menu(self):
        """Create a popup menu over the statusicon."""
        # (Name, stock-id, label, accel, tooltip, callback)
        action_entries = [
            ("About", Gtk.STOCK_ABOUT, None, None, None,
                self.app.on_about_dialog_show),
            ("Quit", Gtk.STOCK_QUIT, None, None, None, self.on_quit),
            ]
        ui_info = """\
        <ui>
            <popup name="Popup">
                <menuitem action="About"/>
                <separator/>
                <menuitem action="Quit"/>
            </popup>
        </ui>
        """
        actions = Gtk.ActionGroup("StatusIconPopup")
        actions.add_actions(action_entries)
        ui = Gtk.UIManager()
        ui.insert_action_group(actions)
        ui.add_ui_from_string(ui_info)
        menu = ui.get_widget("/Popup")
        return menu

    def make_tooltip(self):
        """Generate tooltip content for the network interface."""
        iface = self.iface
        rq = iface.rx_queue
        tq = iface.tx_queue
        if len(rq) > 1:
            rx_average = (rq[-1][1] - rq[0][1])/(rq[-1][0]-rq[0][0])
            tx_average = (tq[-1][1] - tq[0][1])/(tq[-1][0]-tq[0][0])
        else:
            rx_average = 0
            tx_average = 0

        rx_now = humanize_number(rq[-1][2])
        tx_now = humanize_number(tq[-1][2])
        rx_average = humanize_number(rx_average)
        tx_average = humanize_number(tx_average)

        txt = """\
Interface: {0}
In/Out(current): {1}/{2}
In/Out(average): {3}/{4}""".format(
                        iface.ifid,
                        rx_now, tx_now,
                        rx_average, tx_average)
        return txt

    def update_scale(self):
        """Set the scale factor for speed rate so that the speed fit into icon
        height."""
        surface = self.ctx.get_target()
        #   whorfin - this gets set as 0 and we die
        height = surface.get_height()
        # hax
        height = 64

        portion = self.portion
        iface = self.iface
        total = max(iface.total_rate_queue)
        # Don't display slow bandwidth as high.
        if total < self.rate_low:
            portion = self.portion_low
        if total > 0:
            scale = float(height)*portion/total
            # don't scale if not needed
            if ((self.scale == 0) or
                    (abs(self.scale - scale)/self.scale > 0.3) or
                    (height < self.scale*total)):
                self.scale = scale
                #print("***Scale", scale, total, max_rx[2], max_tx[2])
                print("***update_scale - self.scale: {}, height: {}, total: {}, portion: {}".format(self.scale, height, total, portion))
        return True

    def get_speed(self, maxspeed):
        """Fetch upload/download speed for the network interface."""
        rx_list = []
        tx_list = []
        iface = self.iface

        print("***get_speed - self.scale: {}, maxspeed: {}".format(self.scale, maxspeed))
        if self.scale == 0:
            self.update_scale()
        scale = self.scale
        if scale == 0:
            scale = 1
        for i in range(len(iface.rx_queue)):
            rspeed = iface.rx_queue[i][2]*scale
            tspeed = iface.tx_queue[i][2]*scale
            if (rspeed + tspeed) > maxspeed:
                self.update_scale()
                rx_list, tx_list = self.get_speed(maxspeed)
                return rx_list, tx_list
            else:
                rx_list.append(rspeed)
                tx_list.append(tspeed)
        return rx_list, tx_list

    def update(self):
        """Update statusicon content."""
        iface = self.iface
        iface.update()
        tooltxt = self.make_tooltip()
        self.statusicon.set_tooltip_text(tooltxt)
        ctx = self.ctx
        surface = ctx.get_target()

        graph_width = surface.get_width()
        graph_height = surface.get_height()

        # whorfin - and again here it is 0
        graph_height = 64
        rx_list, tx_list = self.get_speed(graph_height)

        slot_width = float(graph_width)/iface.maxlen
        xoffset = iface.maxlen - len(rx_list)

        self.ctx.paint()
        ctx.save()
        ctx.set_source_rgb(*self.rx_color)
        ctx.new_path()
        for i in range(len(rx_list)):
            speed = rx_list[i]
            # top-left = (0, 0), x, y = topleft
            ctx.rectangle(slot_width*(i+xoffset),
                    graph_height - speed, slot_width, speed)
        ctx.fill()

        ctx.set_source_rgb(*self.tx_color)
        ctx.new_path()
        for i in range(len(tx_list)):
            speed = tx_list[i]
            ctx.rectangle(slot_width*(i+xoffset),
                    0, slot_width, speed)
        ctx.fill()
        ctx.restore()
        pixbuf = Gdk.pixbuf_get_from_surface(surface, 0, 0,
                graph_width, graph_height)
        self.statusicon.set_from_pixbuf(pixbuf)
        return True

    def start_timers(self):
        """Setup update timers for the statusicon."""
        self.update_id = GObject.timeout_add(self.update_timeout, self.update)
        self.update_scale_id = GObject.timeout_add(self.update_scale_timeout,
                self.update_scale)

    def on_quit(self, *dummy):
        self.app.quit()

    def on_destroy(self, *args):
        GObject.remove(self.update_id)
        GObject.remove(self.update_scale_id)

class App:
    """Application control point."""
    def __init__(self):
        self.iface_map = {}
        self.iface_update_timeout = 5000
    def update_iface(self):
        """Lookup new or disable network interfaces on the OS."""
        faces = os.listdir(sys_net_path)
        for f in faces:
            if f == "lo": continue
            if f not in self.iface_map:
                iface = IFace(f)
                if iface.isup():
                    self.iface_map[f] = StatusBarIF(self, iface)
                    self.iface_map[f].start_timers()
        # update status
        for fid, face in list(self.iface_map.items()):
            if not face.iface.isup():
                face.destroy()
                del self.iface_map[fid]
        return True

    def on_about_dialog_show(self, *args):
        if not hasattr(self, "about_dialog"):
            ad = self.about_dialog = Gtk.AboutDialog()
            ad.connect("response", hide_window)
            ad.connect("delete-event", hide_window)
            ad.set_program_name("Byte On Panel")
            ad.set_version(__version__)
            ad.set_copyright("Mozbugbox 2011")
            ad.set_license("GPL 3.0 or later\n"+__doc__)
            ad.set_website(
                    "https://bitbucket.org/mozbugbox/byteonpanel/wiki/Home")
            ad.set_website_label("Byte On Panel Wiki")
            ad.set_authors(["Mozbugbox"])
        self.about_dialog.present()

    def start(self):
        GObject.timeout_add(self.iface_update_timeout, self.update_iface)
        self.update_iface()
        Gtk.main()
    def quit(self):
        Gtk.main_quit()

def main():
    app = App()
    app.start()

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        Gtk.main_quit()

