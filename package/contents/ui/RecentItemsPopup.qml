/*
    SPDX-FileCopyrightText: 2026 FancyTasksNG contributors
    SPDX-License-Identifier: GPL-2.0-or-later

    RecentItemsPopup.qml
    Custom right-click popup showing pinned ("Ulubione") and recent ("Ostatnie")
    items for the clicked task, read from ~/.local/share/recently-used.xbel.

    Each row: [favicon 16px] [title/URL, elided] [pin/unpin button]
    Footer:   [Wiecej opcji] -> emits moreOptionsRequested() signal

    Uses PlasmaCore.Dialog -- native Plasma window, not clipped by panel bounds.
*/

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtCore

import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

import "code/singletones"

PlasmaCore.AppletPopup {
    id: popup

    // Public API
    required property string appId
    required property Item   taskItem

    property var  pendingArgs:         null
    property var  urlTitleCache:        ({})
    property bool historyCacheLoaded:   false

    signal moreOptionsRequested()

    visible:                false
    visualParent:           taskItem
    popupDirection: {
        if (Plasmoid.location === PlasmaCore.Types.TopEdge)   return Qt.BottomEdge;
        if (Plasmoid.location === PlasmaCore.Types.LeftEdge)  return Qt.RightEdge;
        if (Plasmoid.location === PlasmaCore.Types.RightEdge) return Qt.LeftEdge;
        return Qt.TopEdge; // BottomEdge panel (default)
    }
    hideOnWindowDeactivate: true

    readonly property int icoSize:   Kirigami.Units.iconSizes.small
    readonly property int maxRecent: 5
    readonly property var fileManagerIds: ["org.kde.dolphin", "org.kde.krusader", "org.gnome.nautilus", "pcmanfm", "nemo", "thunar", "doublecmd"]

    // --- Browser history (async, preloaded on startup) ---
    Plasma5Support.DataSource {
        id: historySource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = (data && data["stdout"]) || ""
            disconnectSource(sourceName)
            if (!stdout.trim()) return
            try {
                var entries = JSON.parse(stdout)
                var cache = {}
                for (var i = 0; i < entries.length; i++) {
                    var e = entries[i]
                    if (e.url && e.title) cache[e.url] = e.title
                }
                popup.urlTitleCache = cache
                popup.historyCacheLoaded = true
                // Odśwież modele jeśli popup jest otwarty
                if (popup.visible) {
                    popup.doRefreshPinned()
                    popup.doLoadSync()
                }
            } catch(err) {
                console.warn("FancyTasks: get-history parse error:", err)
            }
        }
    }

    Component.onCompleted: popup.loadBrowserHistory()

    component ItemRow: Item {
        id: row

        required property string href
        required property string title
        required property bool   pinned

        implicitHeight: rowLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
        implicitWidth:  rowLayout.implicitWidth

        HoverHandler { id: rowHover }

        Rectangle {
            anchors { fill: parent; margins: -1 }
            color:   Kirigami.Theme.highlightColor
            opacity: rowHover.hovered ? 0.15 : 0.0
            radius:  3
            z:       -1
            Behavior on opacity { NumberAnimation { duration: 80 } }
        }

        TapHandler {
            cursorShape: Qt.PointingHandCursor
            onTapped:    { Qt.openUrlExternally(row.href); popup.close() }
        }

        RowLayout {
            id: rowLayout
            anchors {
                left:           parent.left
                right:          parent.right
                verticalCenter: parent.verticalCenter
                leftMargin:     Kirigami.Units.smallSpacing
                rightMargin:    Kirigami.Units.smallSpacing
            }
            spacing: Kirigami.Units.smallSpacing

            Item {
                width:  popup.icoSize
                height: popup.icoSize
                Layout.alignment: Qt.AlignVCenter

                Image {
                    id: faviconImg
                    anchors.fill: parent
                    source:       popup.faviconFor(row.href)
                    visible:      status === Image.Ready
                    asynchronous: true
                    smooth:       true
                    fillMode:     Image.PreserveAspectFit
                    cache:        true
                }
                Kirigami.Icon {
                    anchors.fill: parent
                    visible:      faviconImg.status !== Image.Ready
                    source: {
                        if (row.href.startsWith("http://") || row.href.startsWith("https://"))
                            return "internet-web-browser"
                        return "document-open"
                    }
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth:  true
                Layout.alignment:  Qt.AlignVCenter
                text:              row.title
                elide:             Text.ElideRight
                font.family:    Kirigami.Theme.smallFont.family
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight:    Font.Normal
                font.bold:      false
            }

            PlasmaComponents3.ToolButton {
                id: pinBtn
                Layout.alignment: Qt.AlignVCenter

                visible: rowHover.hovered || row.pinned
                opacity: visible ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 80 } }

                implicitWidth:  popup.icoSize + 8
                implicitHeight: popup.icoSize + 8
                flat:    true
                display: QQC2.AbstractButton.IconOnly

                icon.name:   row.pinned ? "starred-symbolic" : "non-starred-symbolic"
                icon.width:  popup.icoSize
                icon.height: popup.icoSize

                PlasmaComponents3.ToolTip {
                    text: row.pinned
                          ? Wrappers.i18n("Usuń z ulubionych")
                          : Wrappers.i18n("Dodaj do ulubionych")
                }

                onClicked: popup.doTogglePin(row.href, row.title)
            }
        }
    }

    mainItem: Item {
        implicitWidth:  320
        implicitHeight: contentCol.implicitHeight

        // ListModels here — not at Dialog level (defaultProperty = QQuickItem*)
        ListModel { id: pinnedModel }
        ListModel { id: recentModel }

        Timer {
            id: moreOptionsTimer
            interval: 150
            repeat:   false
            onTriggered: popup.moreOptionsRequested()
        }

        ColumnLayout {
            id: contentCol
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 0

            PlasmaComponents3.Label {
                visible:             pinnedModel.count > 0
                Layout.fillWidth:    true
                Layout.leftMargin:   Kirigami.Units.smallSpacing
                Layout.topMargin:    Kirigami.Units.smallSpacing / 2
                Layout.bottomMargin: 2
                text:                Wrappers.i18n("Ulubione:")
                font.bold:           true
                font.family:         Kirigami.Theme.smallFont.family
                font.pointSize:      Kirigami.Theme.smallFont.pointSize
                opacity:             0.7
            }

            Repeater {
                model: pinnedModel
                delegate: ItemRow {
                    Layout.fillWidth: true
                }
            }

            PlasmaComponents3.Label {
                visible:             recentModel.count > 0
                Layout.fillWidth:    true
                Layout.leftMargin:   Kirigami.Units.smallSpacing
                Layout.topMargin:    pinnedModel.count > 0 ? Kirigami.Units.smallSpacing : Kirigami.Units.smallSpacing / 2
                Layout.bottomMargin: 2
                text:                Wrappers.i18n("Ostatnie:")
                font.bold:           true
                font.family:         Kirigami.Theme.smallFont.family
                font.pointSize:      Kirigami.Theme.smallFont.pointSize
                opacity:             0.7
            }

            Repeater {
                model: recentModel
                delegate: ItemRow {
                    Layout.fillWidth: true
                }
            }

            Rectangle {
                Layout.fillWidth:    true
                Layout.topMargin:    Kirigami.Units.smallSpacing
                Layout.bottomMargin: 1
                height: 1
                color: Kirigami.ColorUtils.linearInterpolation(
                           Kirigami.Theme.backgroundColor,
                           Kirigami.Theme.textColor, 0.15)
            }

            Item {
                Layout.fillWidth: true
                implicitHeight:   moreRow.implicitHeight + Kirigami.Units.smallSpacing * 2

                HoverHandler { id: moreHover }

                Rectangle {
                    anchors { fill: parent; margins: -1 }
                    color:   Kirigami.Theme.highlightColor
                    opacity: moreHover.hovered ? 0.15 : 0.0
                    radius:  3
                    z:       -1
                    Behavior on opacity { NumberAnimation { duration: 80 } }
                }

                TapHandler {
                    cursorShape: Qt.PointingHandCursor
                    onTapped: {
                        popup.visible = false
                        moreOptionsTimer.restart()
                    }
                }

                RowLayout {
                    id: moreRow
                    anchors {
                        left:           parent.left
                        right:          parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin:     Kirigami.Units.smallSpacing
                        rightMargin:    Kirigami.Units.smallSpacing
                    }
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        Layout.preferredWidth:  popup.icoSize
                        Layout.preferredHeight: popup.icoSize
                        Layout.alignment: Qt.AlignVCenter
                        source: "application-menu"
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text:             Wrappers.i18n("Więcej opcji…")
                        font.family:    Kirigami.Theme.smallFont.family
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.weight:    Font.Normal
                        font.bold:      false
                    }
                }
            }
        }
    }

    function open()  { popup.visible = true  }
    function close() { popup.visible = false }

    function tryLoad(contextMenuArgs) {
        pendingArgs = contextMenuArgs
        doRefreshPinned()
        doLoadSync()
        return pinnedModel.count > 0 || recentModel.count > 0
    }

    function faviconFor(href) {
        if (!href) return ""
        if (href.startsWith("http://") || href.startsWith("https://")) {
            var afterScheme = href.substring(href.indexOf("://") + 3)
            var slashIdx    = afterScheme.indexOf("/")
            var host        = slashIdx >= 0 ? afterScheme.substring(0, slashIdx) : afterScheme
            var portIdx = host.lastIndexOf(":")
            if (portIdx > 0) host = host.substring(0, portIdx)
            return "https://icons.duckduckgo.com/ip3/" + host + ".ico"
        }
        return ""
    }

    function titleFor(href) {
        if (!href) return ""
        // 1. Sprawdź cache historii przeglądarki (prawdziwy tytuł strony)
        if (popup.urlTitleCache && popup.urlTitleCache[href])
            return popup.urlTitleCache[href]
        // 2. Plik — pokaż nazwę pliku
        if (href.startsWith("file://")) {
            var path      = decodeURIComponent(href.substring(7))
            var lastSlash = path.lastIndexOf("/")
            return lastSlash >= 0 ? path.substring(lastSlash + 1) : path
        }
        // 3. Dla http/https bez tytułu w cache — pokaż pełny URL (bez domeny)
        return href
    }

    // Ładuje cache plik synchronicznie (jeśli DataSource nie zdążył się wykonać)
    function loadHistoryCacheFile() {
        var homeUrl  = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString()
        var homePath = homeUrl.replace(/^file:\/\//, "")
        var cacheUrl = "file://" + homePath + "/.cache/fancytasks-history.json"
        var xhr = new XMLHttpRequest()
        xhr.open("GET", cacheUrl, false)
        try { xhr.send() } catch(e) { return }
        if (xhr.status !== 0 && xhr.status !== 200) return
        try {
            var entries = JSON.parse(xhr.responseText)
            var cache   = {}
            for (var i = 0; i < entries.length; i++) {
                var e = entries[i]
                if (e.url && e.title) cache[e.url] = e.title
            }
            popup.urlTitleCache      = cache
            popup.historyCacheLoaded = true
        } catch(e) {}
    }

    function loadBrowserHistory() {
        var scriptUrl  = Qt.resolvedUrl("../code/get-history.py").toString()
        // DataSource executable engine nie używa shella — nie wolno cytować ścieżki ani używać 2>/dev/null
        var scriptPath = scriptUrl.replace(/^file:\/\//, "")
        historySource.connectSource("python3 " + scriptPath)
    }

    function matchesApp(appName) {
        if (!popup.appId || !appName) return false
        var a = appName.toLowerCase().replace(/_/g, ".")
        var b = popup.appId.toLowerCase()
        if (a === b) return true
        if (a.endsWith("." + b)) return true
        if (b.endsWith("." + a)) return true
        return a.split(".").pop() === b.split(".").pop()
    }

    function doRefreshPinned() {
        pinnedModel.clear()
        var list   = Plasmoid.configuration.pinnedRecentItems || []
        var prefix = popup.appId + "|"
        for (var i = 0; i < list.length; i++) {
            if (!list[i].startsWith(prefix)) continue
            var rest  = list[i].substring(prefix.length)
            var sep   = rest.indexOf("|")
            var href  = sep >= 0 ? rest.substring(0, sep)      : rest
            var title = sep >= 0 ? rest.substring(sep + 1)     : titleFor(href)
            if (href) pinnedModel.append({ href: href, title: title || titleFor(href), pinned: true })
        }
    }

    function doTogglePin(href, title) {
        var key     = popup.appId + "|" + href + "|" + title.replace(/\|/g, " ")
        var current = Plasmoid.configuration.pinnedRecentItems || []
        var newList = []
        var found   = false
        for (var i = 0; i < current.length; i++) {
            if (current[i] === key) {
                found = true
            } else {
                newList.push(current[i])
            }
        }
        if (!found) newList.push(key)
        Plasmoid.configuration.pinnedRecentItems = newList
        doRefreshPinned()
        doLoadSync()
    }

    function doLoadSync() {
        if (!popup.appId) return
        // Wczytaj cache z pliku synchronicznie jeśli DataSource jeszcze nie gotowy
        if (!popup.historyCacheLoaded) loadHistoryCacheFile()
        var rawPath = StandardPaths.writableLocation(StandardPaths.GenericDataLocation)
                          .toString().replace(/^file:\/\//, "")
        var xbelUrl = "file://" + rawPath + "/recently-used.xbel"

        var xhr = new XMLHttpRequest()
        xhr.open("GET", xbelUrl, false)
        try { xhr.send() } catch (e) { return }
        if (xhr.status !== 0 && xhr.status !== 200) return

        parseXBEL(xhr.responseText)
    }

    function parseXBEL(text) {
        if (!text) return
        var items = []

        var parts = text.split("<bookmark ")
        for (var i = 1; i < parts.length; i++) {
            var section  = parts[i]
            var closeIdx = section.indexOf("</bookmark>")
            if (closeIdx >= 0) section = section.substring(0, closeIdx)

            var hrefM = /href="([^"]*)"/.exec(section)
            if (!hrefM) continue
            var href = hrefM[1]
                .replace(/&amp;/g,  "&")
                .replace(/&lt;/g,   "<")
                .replace(/&gt;/g,   ">")
                .replace(/&quot;/g, '"')
                .replace(/&apos;/g, "'")

            if (href.startsWith("appstream://") ||
                href.startsWith("apt://")       ||
                href.startsWith("snap://")      ||
                href.startsWith("filenamesearch:") ||
                href.startsWith("tar://")       ||
                href.startsWith("search:"))     continue

            // Dla file managerów — pokaż tylko foldery (file:// bez rozszerzenia)
            var isFileMgr = popup.fileManagerIds.indexOf(popup.appId.toLowerCase()) >= 0
            if (isFileMgr) {
                if (!href.startsWith("file://")) continue
                var decoded   = decodeURIComponent(href.substring(7)).replace(/\/$/, "")
                var lastSlash = decoded.lastIndexOf("/")
                var basename  = lastSlash >= 0 ? decoded.substring(lastSlash + 1) : decoded
                var dotPos    = basename.indexOf(".")
                if (dotPos > 0) continue  // ma rozszerzenie → to plik, nie folder
            }

            var visitedM  = /visited="([^"]*)"/.exec(section)
            var modifiedM = /modified="([^"]*)"/.exec(section)
            var visited   = (visitedM  ? visitedM[1]  : "")
                         || (modifiedM ? modifiedM[1] : "")

            var titleM = /<title>([^<]*)<\/title>/.exec(section)
            var title  = titleM ? titleM[1].trim() : ""
            if (!title) title = titleFor(href)

            var appsM = /<bookmark:applications>([\s\S]*?)<\/bookmark:applications>/.exec(section)
            if (!appsM) continue
            var nameRe = /name="([^"]*)"/g
            var nameM2
            var appMatches = false
            while ((nameM2 = nameRe.exec(appsM[1])) !== null) {
                if (matchesApp(nameM2[1])) { appMatches = true; break }
            }

            if (appMatches && href) items.push({ href: href, title: title, visited: visited })
        }

        items.sort(function(a, b) {
            return a.visited < b.visited ? 1 : a.visited > b.visited ? -1 : 0
        })

        var pinnedSet = {}
        for (var j = 0; j < pinnedModel.count; j++) {
            pinnedSet[pinnedModel.get(j).href] = true
        }

        recentModel.clear()
        var count = 0
        for (var k = 0; k < items.length && count < popup.maxRecent; k++) {
            if (!pinnedSet[items[k].href]) {
                recentModel.append({ href: items[k].href, title: items[k].title, pinned: false })
                count++
            }
        }
    }
}
