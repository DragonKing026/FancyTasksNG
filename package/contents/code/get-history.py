#!/usr/bin/env python3
# get-history.py
#
# Tryb 1 — bez argumentów:
#   Czyta historię przeglądarek (Chromium/Firefox), zapisuje cache JSON i wypisuje na stdout.
#
# Tryb 2 — --app <agent> [--limit N]:
#   Szybkie zapytanie do KDE Activity DB dla konkretnej aplikacji.
#   Wypisuje N ostatnich zasobów na stdout (JSON). Brak zapisu cache, brak skanowania przeglądarek.

import sqlite3, shutil, os, json, glob, argparse

home = os.path.expanduser('~')

# ── Tryb 2: file manager — tylko 10 ostatnich folderów ────────────────────────

FILE_MANAGER_IDS = {
    'org.kde.dolphin', 'dolphin',
    'org.kde.krusader', 'krusader',
    'org.gnome.nautilus', 'nautilus',
    'pcmanfm', 'nemo', 'thunar', 'doublecmd', 'spacefm',
}

def _read_xdg_user_dirs():
    """Zwraca słownik ścieżka→nazwa_ikony dla folderów XDG użytkownika."""
    icon_map = {
        'XDG_DOWNLOAD_DIR':   'folder-download',
        'XDG_PICTURES_DIR':   'folder-pictures',
        'XDG_MUSIC_DIR':      'folder-music',
        'XDG_VIDEOS_DIR':     'folder-videos',
        'XDG_DOCUMENTS_DIR':  'folder-documents',
        'XDG_DESKTOP_DIR':    'user-desktop',
        'XDG_TEMPLATES_DIR':  'folder-templates',
        'XDG_PUBLICSHARE_DIR':'folder-publicshare',
    }
    result = {home: 'user-home'}
    xdg_file = os.path.join(home, '.config/user-dirs.dirs')
    try:
        with open(xdg_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, val = line.split('=', 1)
                icon = icon_map.get(key.strip())
                if icon:
                    path = val.strip().strip('"').replace('$HOME', home)
                    result[path] = icon
    except Exception:
        pass
    return result

_XDG_ICONS = None

def get_folder_icon(path):
    """Zwraca nazwę ikony KDE dla podanego katalogu."""
    global _XDG_ICONS
    if _XDG_ICONS is None:
        _XDG_ICONS = _read_xdg_user_dirs()
    # Najpierw: niestandardowa ikona z pliku .directory
    dir_file = os.path.join(path, '.directory')
    if os.path.isfile(dir_file):
        try:
            import configparser
            cp = configparser.ConfigParser()
            cp.read(dir_file, encoding='utf-8')
            icon = cp.get('Desktop Entry', 'Icon', fallback=None)
            if icon:
                return icon
        except Exception:
            pass
    # Następnie: mapa folderów XDG
    return _XDG_ICONS.get(path, 'folder')

VSCODE_IDS = {
    'com.visualstudio.code', 'code', 'code-oss', 'vscodium',
    'com.vscodium.codium', 'org.vscodium.vscodium',
}

def mode_app(agent, limit):
    a = agent.lower()
    short = a.split('.')[-1]
    if a in FILE_MANAGER_IDS or short in FILE_MANAGER_IDS:
        query_filemanager(agent, limit)
    elif a in VSCODE_IDS or short in VSCODE_IDS or 'vscode' in a or ('visualstudio' in a and 'code' in a):
        query_vscode(limit)
    else:
        query_browser(agent, limit)

def query_filemanager(agent, limit):
    db = os.path.join(home, '.local/share/kactivitymanagerd/resources/database')
    if not os.path.exists(db):
        print('[]'); return
    tmp = '/tmp/_fancytasks_kactivity.db'
    # Kopiuj również WAL i SHM — bez nich SQLite nie widzi niezapisanych zmian
    for ext in ('', '-wal', '-shm'):
        src = db + ext
        if os.path.exists(src):
            shutil.copy2(src, tmp + ext)
    try:
        conn = sqlite3.connect(tmp)
        short = agent.split('.')[-1]
        # ResourceEvent — świeże dane z WAL, ORDER BY end DESC żeby najnowsze pierwsze
        rows = [r[0] for r in conn.execute(
            "SELECT targettedResource FROM ResourceEvent "
            "WHERE (initiatingAgent = ? OR initiatingAgent = ?) "
            "AND targettedResource LIKE 'file://%' OR targettedResource LIKE '/%' "
            "ORDER BY end DESC LIMIT ?",
            (agent, short, limit * 5)
        ) if r[0]]
        conn.close()
    except Exception:
        rows = []
    finally:
        for ext in ('', '-wal', '-shm'):
            try: os.unlink(tmp + ext)
            except Exception: pass

    SKIP_SCHEMES = ('filenamesearch:', 'zip://', 'tar://', 'search:', 'appstream:', 'apt:', 'snap:')
    output, seen = [], set()
    for resource in rows:
        url = ('file://' + resource) if resource.startswith('/') else resource
        if any(url.startswith(s) for s in SKIP_SCHEMES): continue
        if url in seen: continue
        seen.add(url)
        path = resource.rstrip('/')
        basename = path.rsplit('/', 1)[-1] if '/' in path else path
        output.append({"url": url, "title": basename or url, "icon": get_folder_icon(path)})
        if len(output) >= limit:
            break
    print(json.dumps(output, ensure_ascii=False))

def _vscode_ssh_label(folder_uri):
    """Dla URI vscode-remote://ssh-remote+<hex-json>/path zwraca 'folder @ hostname'."""
    import binascii
    from urllib.parse import unquote
    try:
        # Przykład: vscode-remote://ssh-remote%2B7b22686f73744e616d65223a2254656e616e746f2e706c227d/home/tenanto/app
        decoded = unquote(folder_uri)
        # Wyodrębnij sekcję między // a pierwszym /ścieżka
        # format: vscode-remote://ssh-remote+<hex>/path
        rest = decoded[len('vscode-remote://ssh-remote+'):]
        hex_part, _, remote_path = rest.partition('/')
        # hex_part to JSON zakodowany jako hex: {"hostName":"..."}
        host_json = binascii.unhexlify(hex_part).decode('utf-8')
        host_data = json.loads(host_json)
        hostname = host_data.get('hostName', hex_part)
        folder_name = remote_path.rstrip('/').rsplit('/', 1)[-1] or remote_path
        return f'{folder_name} @ {hostname}', 'network-server'
    except Exception:
        return None, 'network-server'


def query_vscode(limit):
    """Zwraca ostatnio otwarte projekty/foldery VS Code, posortowane po czasie dostępu."""
    from urllib.parse import unquote

    # Lokalizacje workspaceStorage — natywna i Flatpak
    workspace_dirs = [
        os.path.join(home, '.config/Code/User/workspaceStorage'),
        os.path.join(home, '.var/app/com.visualstudio.code/config/Code/User/workspaceStorage'),
        os.path.join(home, '.config/VSCodium/User/workspaceStorage'),
        os.path.join(home, '.var/app/com.vscodium.codium/config/VSCodium/User/workspaceStorage'),
    ]

    items = []
    seen_uris = set()

    for ws_dir in workspace_dirs:
        if not os.path.isdir(ws_dir):
            continue
        for ws_json in glob.glob(os.path.join(ws_dir, '*/workspace.json')):
            try:
                data = json.load(open(ws_json))
                folder_uri = data.get('folder', '')
                if not folder_uri:
                    continue
                mtime = os.path.getmtime(os.path.dirname(ws_json))
                if folder_uri not in seen_uris:
                    seen_uris.add(folder_uri)
                    items.append((mtime, folder_uri))
            except Exception:
                pass

    # Sortuj od najświeższych, ogranicz do limitu
    items.sort(key=lambda x: x[0], reverse=True)
    items = items[:limit]

    output = []
    for _, url in items:
        if url.startswith('file://'):
            path = unquote(url[len('file://'):]).rstrip('/')
            basename = path.rsplit('/', 1)[-1] if '/' in path else path
            icon = get_folder_icon(path) if os.path.isdir(path) else 'folder'
            output.append({"url": url, "title": basename or url, "icon": icon})
        elif 'ssh-remote' in url:
            title, icon = _vscode_ssh_label(url)
            if not title:
                title = url
            output.append({"url": url, "title": title, "icon": icon})
        else:
            # WSL, Dev Container, tunnel itp.
            label = unquote(url).rsplit('/', 1)[-1] or url
            output.append({"url": url, "title": label, "icon": "network-server"})

    print(json.dumps(output, ensure_ascii=False))


def query_browser(agent, limit):
    a = agent.lower()
    chromium_paths, firefox_patterns = [], []
    if 'brave' in a:
        chromium_paths = [
            f'{home}/.config/BraveSoftware/Brave-Browser/Default/History',
            f'{home}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default/History',
        ]
    elif 'chrome' in a:
        chromium_paths = [
            f'{home}/.config/google-chrome/Default/History',
            f'{home}/.var/app/com.google.Chrome/config/google-chrome/Default/History',
        ]
    elif 'chromium' in a:
        chromium_paths = [
            f'{home}/.config/chromium/Default/History',
            f'{home}/.var/app/org.chromium.Chromium/config/chromium/Default/History',
        ]
    elif 'opera-gx' in a or 'operagx' in a:
        chromium_paths = [f'{home}/.config/opera-gx/Default/History']
    elif 'opera' in a:
        chromium_paths = [
            f'{home}/.config/opera/Default/History',
            f'{home}/.var/app/com.opera.Opera/config/opera/Default/History',
        ]
    elif 'edge' in a or 'microsoft' in a:
        chromium_paths = [
            f'{home}/.config/microsoft-edge/Default/History',
            f'{home}/.var/app/com.microsoft.Edge/config/microsoft-edge/Default/History',
        ]
    elif 'vivaldi' in a:
        chromium_paths = [f'{home}/.config/vivaldi/Default/History']
    elif 'thorium' in a:
        chromium_paths = [f'{home}/.config/thorium/Default/History']
    elif 'firefox' in a or 'mozilla' in a:
        firefox_patterns = [
            f'{home}/.mozilla/firefox/*/places.sqlite',
            f'{home}/.var/app/org.mozilla.firefox/.mozilla/firefox/*/places.sqlite',
            f'{home}/.var/app/org.mozilla.firefox/data/.mozilla/firefox/*/places.sqlite',
        ]
    elif 'librewolf' in a:
        firefox_patterns = [
            f'{home}/.var/app/io.gitlab.librewolf-community/.librewolf/*/places.sqlite',
            f'{home}/.librewolf/*/places.sqlite',
        ]
    elif 'waterfox' in a:
        firefox_patterns = [f'{home}/.waterfox/*/places.sqlite']
    else:
        print('[]'); return

    rows = []
    for path in chromium_paths:
        if not os.path.exists(path): continue
        tmp = '/tmp/_fancytasks_browser.db'
        try:
            shutil.copy2(path, tmp)
            conn = sqlite3.connect(tmp)
            rows = [{"url": u, "title": t} for u, t in conn.execute(
                "SELECT url, title FROM urls "
                "WHERE title IS NOT NULL AND title != '' "
                "ORDER BY last_visit_time DESC LIMIT ?", (limit,)
            ) if u and t]
            conn.close()
        except Exception: pass
        finally:
            try: os.unlink(tmp)
            except: pass
        if rows: break

    for pattern in firefox_patterns:
        for f in glob.glob(pattern):
            if not os.path.exists(f): continue
            tmp = '/tmp/_fancytasks_firefox.db'
            try:
                shutil.copy2(f, tmp)
                conn = sqlite3.connect(tmp)
                rows = [{"url": u, "title": t} for u, t in conn.execute(
                    "SELECT url, title FROM moz_places "
                    "WHERE title IS NOT NULL AND title != '' "
                    "ORDER BY last_visit_date DESC LIMIT ?", (limit,)
                ) if u and t]
                conn.close()
            except Exception: pass
            finally:
                try: os.unlink(tmp)
                except: pass
            if rows: break
        if rows: break

    print(json.dumps(rows[:limit], ensure_ascii=False))


# ── Tryb 1: historia przeglądarek ─────────────────────────────────────────────

results = {}   # url -> title

def query_chromium(dbpath):
    if not os.path.exists(dbpath):
        return
    tmp = '/tmp/_fancytasks_chromium_history.db'
    try:
        shutil.copy2(dbpath, tmp)
        conn = sqlite3.connect(tmp)
        for url, title in conn.execute(
            "SELECT url, title FROM urls "
            "WHERE title IS NOT NULL AND title != '' "
            "ORDER BY last_visit_time DESC LIMIT 10000"
        ):
            if url and title and url not in results:
                results[url] = title
        conn.close()
    except Exception:
        pass
    finally:
        try: os.unlink(tmp)
        except Exception: pass

def query_firefox(dbpath):
    if not os.path.exists(dbpath):
        return
    tmp = '/tmp/_fancytasks_firefox_places.db'
    try:
        shutil.copy2(dbpath, tmp)
        conn = sqlite3.connect(tmp)
        for url, title in conn.execute(
            "SELECT url, title FROM moz_places "
            "WHERE title IS NOT NULL AND title != '' "
            "ORDER BY last_visit_date DESC LIMIT 10000"
        ):
            if url and title and url not in results:
                results[url] = title
        conn.close()
    except Exception:
        pass
    finally:
        try: os.unlink(tmp)
        except Exception: pass

def mode_browsers():
    chromium_paths = [
        f'{home}/.config/opera-gx/Default/History',
        f'{home}/.config/opera/Default/History',
        f'{home}/.config/google-chrome/Default/History',
        f'{home}/.config/chromium/Default/History',
        f'{home}/.config/BraveSoftware/Brave-Browser/Default/History',
        f'{home}/.config/microsoft-edge/Default/History',
        f'{home}/.config/vivaldi/Default/History',
        f'{home}/.config/thorium/Default/History',
        f'{home}/.config/ungoogled-chromium/Default/History',
        f'{home}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Default/History',
        f'{home}/.var/app/com.google.Chrome/config/google-chrome/Default/History',
        f'{home}/.var/app/com.microsoft.Edge/config/microsoft-edge/Default/History',
        f'{home}/.var/app/io.github.ungoogled_software.ungoogled_chromium/config/chromium/Default/History',
        f'{home}/.var/app/com.opera.Opera/config/opera/Default/History',
        f'{home}/.var/app/org.chromium.Chromium/config/chromium/Default/History',
    ]
    for path in chromium_paths:
        query_chromium(path)
    for pattern in [
        f'{home}/.config/google-chrome/Profile */History',
        f'{home}/.config/chromium/Profile */History',
        f'{home}/.config/BraveSoftware/Brave-Browser/Profile */History',
        f'{home}/.config/opera-gx/Profile */History',
        f'{home}/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/Profile */History',
        f'{home}/.var/app/com.google.Chrome/config/google-chrome/Profile */History',
    ]:
        for f in glob.glob(pattern):
            query_chromium(f)
    for pattern in [
        f'{home}/.mozilla/firefox/*/places.sqlite',
        f'{home}/snap/firefox/common/.mozilla/firefox/*/places.sqlite',
        f'{home}/.var/app/org.mozilla.firefox/.mozilla/firefox/*/places.sqlite',
        f'{home}/.var/app/org.mozilla.firefox/data/.mozilla/firefox/*/places.sqlite',
        f'{home}/.var/app/io.gitlab.librewolf-community/.librewolf/*/places.sqlite',
        f'{home}/.librewolf/*/places.sqlite',
    ]:
        for f in glob.glob(pattern):
            query_firefox(f)

    output = [{"url": k, "title": v} for k, v in results.items()]
    try:
        with open(os.path.join(home, '.cache/fancytasks-history.json'), 'w', encoding='utf-8') as f:
            json.dump(output, f, ensure_ascii=False)
    except Exception:
        pass
    print(json.dumps(output, ensure_ascii=False))


# ── Main ───────────────────────────────────────────────────────────────────────

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument('--app',   default=None)
parser.add_argument('--limit', type=int, default=10)
args, _ = parser.parse_known_args()

if args.app:
    mode_app(args.app, args.limit)
else:
    mode_browsers()
