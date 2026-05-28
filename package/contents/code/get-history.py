#!/usr/bin/env python3
# get-history.py  —  odczytuje historię przeglądarek + KDE Activity Manager,
# wypisuje JSON: [{"url":..., "title":...}] dla przeglądarek
#                [{"url":..., "title":..., "app":...}] dla file managerów

import sqlite3, shutil, os, json, glob, sys

results = {}          # url -> title (przeglądarki)
app_folders = {}      # agent -> [{"url":..., "title":...}]

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
            "ORDER BY last_visit_time DESC LIMIT 10000"
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
            "ORDER BY last_visit_date DESC LIMIT 10000"
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

# --- KDE Activity Manager (historia nawigacji file managerów) ---
def query_kde_activity():
    db = os.path.expanduser('~/.local/share/kactivitymanagerd/resources/database')
    if not os.path.exists(db):
        return
    tmp = '/tmp/_fancytasks_kactivity.db'
    agents = [
        'org.kde.dolphin', 'dolphin',
        'org.kde.krusader', 'krusader',
        'org.gnome.nautilus', 'nautilus',
        'pcmanfm', 'nemo', 'thunar', 'doublecmd', 'spacefm',
    ]
    placeholders = ','.join('?' * len(agents))
    try:
        shutil.copy2(db, tmp)
        conn = sqlite3.connect(tmp)
        cur = conn.execute(
            f"SELECT initiatingAgent, targettedResource, lastUpdate "
            f"FROM ResourceScoreCache "
            f"WHERE initiatingAgent IN ({placeholders}) "
            f"ORDER BY lastUpdate DESC",
            agents
        )
        for agent, resource, _ in cur:
            if not resource:
                continue
            # Konwertuj ścieżkę absolutną na URL file://
            if resource.startswith('/'):
                url = 'file://' + resource
            else:
                url = resource   # trash:/, remote:/, itp.
            # Tytuł = nazwa ostatniego segmentu ścieżki
            basename = resource.rstrip('/').rsplit('/', 1)[-1] if '/' in resource else resource
            if agent not in app_folders:
                app_folders[agent] = []
            app_folders[agent].append({"url": url, "title": basename or url})
        conn.close()
    except Exception:
        pass
    finally:
        try:
            os.unlink(tmp)
        except Exception:
            pass

query_kde_activity()

output = [{"url": k, "title": v} for k, v in results.items()]
# Dołącz wpisy file managerów z activity DB (z polem "app")
for agent, folders in app_folders.items():
    for f in folders:
        output.append({"url": f["url"], "title": f["title"], "app": agent})

# Zapisz do pliku cache (czytanego synchronicznie przez QML przy starcie)
cache_path = os.path.expanduser('~/.cache/fancytasks-history.json')
try:
    with open(cache_path, 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False)
except Exception:
    pass

print(json.dumps(output, ensure_ascii=False))
