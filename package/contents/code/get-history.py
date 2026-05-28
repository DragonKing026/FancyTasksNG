#!/usr/bin/env python3
# get-history.py  —  odczytuje historię przeglądarek i wypisuje JSON: [{"url":..., "title":...}]
# Kopiuje plik DB do /tmp przed odczytem (unika blokady zajętej przeglądarki).

import sqlite3, shutil, os, json, glob, sys

results = {}   # url -> title (first hit wins)

def query_chromium(dbpath):
    if not os.path.exists(dbpath):
        return
    tmp = '/tmp/_fancytasks_chromium_history.db'
    try:
        shutil.copy2(dbpath, tmp)
        conn = sqlite3.connect(tmp)
        cur = conn.execute(
            "SELECT url, title FROM urls "
            "WHERE title IS NOT NULL AND title != '' "
            "ORDER BY last_visit_time DESC LIMIT 2000"
        )
        for url, title in cur:
            if url and title and url not in results:
                results[url] = title
        conn.close()
    except Exception:
        pass
    finally:
        try:
            os.unlink(tmp)
        except Exception:
            pass

def query_firefox(dbpath):
    if not os.path.exists(dbpath):
        return
    tmp = '/tmp/_fancytasks_firefox_places.db'
    try:
        shutil.copy2(dbpath, tmp)
        conn = sqlite3.connect(tmp)
        cur = conn.execute(
            "SELECT url, title FROM moz_places "
            "WHERE title IS NOT NULL AND title != '' "
            "ORDER BY last_visit_date DESC LIMIT 2000"
        )
        for url, title in cur:
            if url and title and url not in results:
                results[url] = title
        conn.close()
    except Exception:
        pass
    finally:
        try:
            os.unlink(tmp)
        except Exception:
            pass

home = os.path.expanduser('~')

# --- Chromium-based browsers ---
chromium_paths = [
    # Natywne
    f'{home}/.config/opera-gx/Default/History',
    f'{home}/.config/opera/Default/History',
    f'{home}/.config/google-chrome/Default/History',
    f'{home}/.config/chromium/Default/History',
    f'{home}/.config/BraveSoftware/Brave-Browser/Default/History',
    f'{home}/.config/microsoft-edge/Default/History',
    f'{home}/.config/vivaldi/Default/History',
    f'{home}/.config/thorium/Default/History',
    f'{home}/.config/ungoogled-chromium/Default/History',
    # Flatpak
    f'{home}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default/History',
    f'{home}/.var/app/com.google.Chrome/config/google-chrome/Default/History',
    f'{home}/.var/app/com.microsoft.Edge/config/microsoft-edge/Default/History',
    f'{home}/.var/app/io.github.ungoogled_software.ungoogled_chromium/config/chromium/Default/History',
    f'{home}/.var/app/com.opera.Opera/config/opera/Default/History',
    f'{home}/.var/app/org.chromium.Chromium/config/chromium/Default/History',
]
for path in chromium_paths:
    query_chromium(path)

# Multi-profile Chromium (Profile 1, Profile 2, …)
for pattern in [
    f'{home}/.config/google-chrome/Profile */History',
    f'{home}/.config/chromium/Profile */History',
    f'{home}/.config/BraveSoftware/Brave-Browser/Profile */History',
    f'{home}/.config/opera-gx/Profile */History',
    # Flatpak multi-profile
    f'{home}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Profile */History',
    f'{home}/.var/app/com.google.Chrome/config/google-chrome/Profile */History',
]:
    for f in glob.glob(pattern):
        query_chromium(f)

# --- Firefox variants ---
firefox_patterns = [
    f'{home}/.mozilla/firefox/*/places.sqlite',
    f'{home}/snap/firefox/common/.mozilla/firefox/*/places.sqlite',
    f'{home}/snap/firefox/*/firefox/*/places.sqlite',
    f'{home}/.var/app/org.mozilla.firefox/.mozilla/firefox/*/places.sqlite',
    f'{home}/.var/app/org.mozilla.firefox/data/.mozilla/firefox/*/places.sqlite',
    f'{home}/.var/app/io.gitlab.librewolf-community/.librewolf/*/places.sqlite',
    f'{home}/.librewolf/*/places.sqlite',
    f'{home}/.waterfox/*/places.sqlite',
]
for pattern in firefox_patterns:
    for f in glob.glob(pattern):
        query_firefox(f)

output = [{"url": k, "title": v} for k, v in results.items()]

# Zapisz do pliku cache (czytanego synchronicznie przez QML przy starcie)
cache_path = os.path.expanduser('~/.cache/fancytasks-history.json')
try:
    with open(cache_path, 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False)
except Exception:
    pass

print(json.dumps(output, ensure_ascii=False))
