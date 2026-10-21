# dmgbuild settings for the Couch Cube installer window: the app, an arrow and the Applications folder
# on a titled background, and nothing else. Run by scripts/package-release.sh with -D app=… -D background=…
# -D icon=…; the icon positions match the arrow drawn by setup/GenerateIcon.swift --dmg-background.
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821
hide_extensions = [app_name]

window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {app_name: (180, 220), "Applications": (480, 220)}
