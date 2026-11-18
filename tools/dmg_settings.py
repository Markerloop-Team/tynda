# How the Tynda disk image looks when it is opened. Read by dmgbuild, see tools/make_dmg.sh.
# The inside of the window is 640×360 points; tools/make_dmg_background.m draws the picture for that size.

app = defines.get("app", "Tynda.app")  # noqa: F821 — dmgbuild provides `defines`

format = "UDZO"  # compressed, read-only
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"
background = defines["background"]  # noqa: F821

window_rect = ((240, 180), (640, 388))  # 28 of the height is the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {"Tynda.app": (170, 170), "Applications": (470, 170)}
