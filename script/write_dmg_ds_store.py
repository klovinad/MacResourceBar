#!/usr/bin/env python3
import os
import plistlib
import sys

from ds_store import DSStore
from mac_alias import Alias


def alias_bytes(path):
    return Alias.for_file(path).to_bytes()


def main():
    if len(sys.argv) != 2:
        print("usage: write_dmg_ds_store.py <mounted-volume-path>", file=sys.stderr)
        return 2

    volume_path = sys.argv[1]
    ds_store_path = os.path.join(volume_path, ".DS_Store")
    background_path = os.path.join(volume_path, ".background", "background.png")

    browser_window_settings = {
        "ContainerShowSidebar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "WindowBounds": "{{100, 100}, {640, 520}}",
    }

    icon_view_settings = {
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundType": 2,
        "backgroundImageAlias": alias_bytes(background_path),
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": 104.0,
        "labelOnBottom": True,
        "showIconPreview": False,
        "showItemInfo": False,
        "textSize": 12.0,
        "viewOptionsVersion": 1,
    }

    with DSStore.open(ds_store_path, "w+") as store:
        store["."]["bwsp"] = browser_window_settings
        store["."]["icvp"] = icon_view_settings
        store["."]["vSrn"] = ("long", 1)
        store["MacResourceBar.app"]["Iloc"] = (185, 280)
        store["Applications"]["Iloc"] = (455, 280)

    os.chmod(ds_store_path, 0o644)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
