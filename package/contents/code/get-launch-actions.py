#!/usr/bin/env python3
"""
Return and run Desktop Actions for an application in a universal way.

Usage:
  --app <appId> --list
  --app <appId> --run <actionId>
"""

import argparse
import json
import re
import sys


def _import_gio():
    try:
        import gi
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio
        return Gio
    except Exception:
        return None


def _normalize(value):
    return (value or "").strip().lower()


def _candidate_ids(app_id):
    app = _normalize(app_id)
    if not app:
        return []

    out = []

    def add(v):
        if v and v not in out:
            out.append(v)

    add(app)
    if not app.endswith(".desktop"):
        add(app + ".desktop")

    short = app.split(".")[-1]
    add(short)
    if not short.endswith(".desktop"):
        add(short + ".desktop")

    # Common aliases for Code variants
    aliases = {
        "code": ["code.desktop", "com.visualstudio.code.desktop"],
        "code-oss": ["code-oss.desktop", "com.visualstudio.code-oss.desktop"],
        "vscodium": ["vscodium.desktop", "com.vscodium.codium.desktop"],
        "com.visualstudio.code": ["com.visualstudio.code.desktop", "code.desktop"],
        "com.vscodium.codium": ["com.vscodium.codium.desktop", "vscodium.desktop"],
    }
    for item in aliases.get(app, []):
        add(item)

    return out


def _score_appinfo(app_id, info):
    app = _normalize(app_id)
    if not app or info is None:
        return -1

    app_short = app.split(".")[-1]
    app_words = [w for w in re.split(r"[^a-z0-9]+", app) if w]

    info_id = _normalize(getattr(info, "get_id", lambda: "")())
    name = _normalize(getattr(info, "get_name", lambda: "")())
    exe = _normalize(getattr(info, "get_executable", lambda: "")())

    score = 0

    if info_id == app or info_id == app + ".desktop":
        score += 200
    if info_id == app_short or info_id == app_short + ".desktop":
        score += 180

    if app in info_id:
        score += 40
    if app_short and app_short in info_id:
        score += 30

    if app in name:
        score += 20
    if app_short and app_short in name:
        score += 15

    if app in exe:
        score += 25
    if app_short and app_short in exe:
        score += 20

    for w in app_words:
        if len(w) < 3:
            continue
        if w in info_id:
            score += 3
        if w in name:
            score += 2

    return score


def _resolve_app_info(gio, app_id):
    if not app_id:
        return None

    for candidate in _candidate_ids(app_id):
        try:
            info = gio.DesktopAppInfo.new(candidate)
            if info:
                return info
        except Exception:
            pass

    best = None
    best_score = 0
    try:
        for info in gio.AppInfo.get_all():
            try:
                if not isinstance(info, gio.DesktopAppInfo):
                    continue
            except Exception:
                continue

            score = _score_appinfo(app_id, info)
            if score > best_score:
                best_score = score
                best = info
    except Exception:
        return None

    # Require a reasonable match quality to avoid wrong app picks.
    if best_score >= 45:
        return best
    return None


def _list_actions(app_info):
    actions = []
    if not app_info:
        return actions

    try:
        ids = app_info.list_actions() or []
    except Exception:
        ids = []

    for action_id in ids:
        action_name = ""
        try:
            action_name = app_info.get_action_name(action_id) or ""
        except Exception:
            pass

        actions.append(
            {
                "id": action_id,
                "text": action_name or action_id,
            }
        )

    return actions


def _run_action(gio, app_info, action_id):
    if not app_info or not action_id:
        return False

    try:
        # GLib/GIO can launch desktop actions directly without shell command parsing.
        app_info.launch_action(action_id, None)
        return True
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--run")
    args = parser.parse_args()

    gio = _import_gio()
    if gio is None:
        if args.list:
            print("[]")
            return 0
        return 1

    app_info = _resolve_app_info(gio, args.app)

    if args.list:
        print(json.dumps(_list_actions(app_info), ensure_ascii=False))
        return 0

    if args.run:
        ok = _run_action(gio, app_info, args.run)
        return 0 if ok else 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
