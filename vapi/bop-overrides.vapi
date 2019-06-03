[CCode (cprefix = "Gdk", lower_case_cprefix = "gdk_", gir_namespace = "Gdk", gir_version = "3.0")]
namespace GdkOverrides {
        [CCode (cheader_filename = "gdk/gdk.h")]
        public static Gdk.Pixbuf pixbuf_get_from_surface (Cairo.Surface surface, int src_x, int src_y, int width, int height);
}
