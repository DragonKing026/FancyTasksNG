/*
    SPDX-FileCopyrightText: 2026 FancyTasksNG contributors
    SPDX-License-Identifier: GPL-2.0-or-later

    RecentItemsSection.qml
    Displays "Ulubione:" (pinned) and "Ostatnie:" (recent) items
    for the hovered application, read from ~/.local/share/recently-used.xbel.
    Each row shows: favicon/icon | title | pin button — all in one line.
*/

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtCore

import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

import "code/singletones"

ColumnLayout {
    id: root

    // Required: app identifier (e.g. "firefox", "org.kde.kate")
    property string appId: ""
    // Required: launcher URL for extra matching (may be empty)
    property url launcherUrl

    spacing: 0

    // Show the section only when there is something to display
    visible: Plasmoid.configuration.showRecentInTooltip &&
             (pinnedModel.count > 0 || recentModel.count > 0)

    readonly property int maxRecentItems: 5
    readonly property int rowIconSize: Kirigami.Units.iconSizes.small   // 16 px

    // ── Data models ─────────────────────────────────────────────────────────
    ListModel { id: pinnedModel }
    ListModel { id: recentModel }

    // ── Inline row component ─────────────────────────────────────────────────
    // One row: [favicon/icon 16px] [title, elided] [pin button]
    component ItemRow: Item {
        id: row

        required property string itemHref
        required property string itemTitle
        required property string itemFaviconUrl
        required property bool   isPinned

        signal pinToggled()
        signal itemClicked()

        implicitHeight: innerLayout.implicitHeight
        implicitWidth:  innerLayout.implicitWidth

        HoverHandler { id: rowHover }

        // Highlight on hover — Rectangle is child of Item, not RowLayout, so anchors are OK
        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            color: Kirigami.Theme.highlightColor
            opacity: rowHover.hovered ? 0.15 : 0.0
            radius: 3
            z: -1
            Behavior on opacity { NumberAnimation { duration: 80 } }
        }

        RowLayout {
            id: innerLayout
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

        // --- Favicon / file icon ---
        Item {
            width: root.rowIconSize
            height: root.rowIconSize
            Layout.alignment: Qt.AlignVCenter

            // Attempt to load the favicon from the web domain
            Image {
                id: faviconImg
                anchors.fill: parent
                source: row.itemFaviconUrl
                visible: status === Image.Ready
                asynchronous: true
                smooth: true
                fillMode: Image.PreserveAspectFit
                cache: true
            }

            // Fallback: KDE icon
            Kirigami.Icon {
                anchors.fill: parent
                visible: faviconImg.status !== Image.Ready
                source: {
                    if (row.itemHref.startsWith("http://") || row.itemHref.startsWith("https://"))
                        return "internet-web-browser"
                    if (row.itemHref.startsWith("file://"))
                        return "document-open"
                    return "document-open"
                }
            }
        }

        // --- Title label ---
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: row.itemTitle
            elide: Text.ElideRight
            font: Kirigami.Theme.smallFont

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: row.itemClicked()
            }
        }

        // --- Pin / unpin button — visible only on row hover ---
        PlasmaComponents3.ToolButton {
            id: pinBtn
            Layout.alignment: Qt.AlignVCenter
            visible: rowHover.hovered || row.isPinned
            opacity: visible ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 80 } }

            implicitWidth:  Kirigami.Units.iconSizes.small + 4
            implicitHeight: Kirigami.Units.iconSizes.small + 4

            icon.name: row.isPinned ? "starred-symbolic" : "non-starred-symbolic"
            icon.width:  Kirigami.Units.iconSizes.small
            icon.height: Kirigami.Units.iconSizes.small

            flat: true
            display: QQC2.AbstractButton.IconOnly

            PlasmaComponents3.ToolTip {
                text: row.isPinned ? Wrappers.i18n("Usuń z ulubionych") : Wrappers.i18n("Dodaj do ulubionych")
            }

            onClicked: row.pinToggled()
        }
        } // end RowLayout
    }

    // ── Helper functions ─────────────────────────────────────────────────────

    function isPinned(href) {
        for (var i = 0; i < pinnedModel.count; i++) {
            if (pinnedModel.get(i).href === href) return true
        }
        return false
    }

    function togglePin(href, title) {
        var currentList = Plasmoid.configuration.pinnedRecentItems
        var key = root.appId + "|" + href + "|" + title.replace(/\|/g, " ")
        var newList = []
        var found = false
        for (var i = 0; i < currentList.length; i++) {
            if (currentList[i] === key) {
                found = true      // drop it (unpin)
            } else {
                newList.push(currentList[i])
            }
        }
        if (!found) newList.push(key)
        Plasmoid.configuration.pinnedRecentItems = newList
        refreshPinned()
    }

    function refreshPinned() {
        pinnedModel.clear()
        var list = Plasmoid.configuration.pinnedRecentItems
        var prefix = root.appId + "|"
        for (var i = 0; i < list.length; i++) {
            var entry = list[i]
            if (!entry.startsWith(prefix)) continue
            var rest    = entry.substring(prefix.length)
            var sepIdx  = rest.indexOf("|")
            var href    = sepIdx >= 0 ? rest.substring(0, sepIdx)      : rest
            var title   = sepIdx >= 0 ? rest.substring(sepIdx + 1)     : titleFromHref(href)
            if (href) pinnedModel.append({ href: href, title: title || titleFromHref(href) })
        }
    }

    // Match XBEL app name against plasmoid appId
    function matchesApp(appName) {
        if (!root.appId || !appName) return false
        var a = appName.toLowerCase().replace(/_/g, ".")
        var b = root.appId.toLowerCase()
        if (a === b) return true
        if (a.endsWith("." + b)) return true
        if (b.endsWith("." + a)) return true
        // Match last segment: "firefox.firefox" vs "firefox"
        return a.split(".").pop() === b.split(".").pop()
    }

    function faviconUrl(href) {
        if (!href) return ""
        if (href.startsWith("http://") || href.startsWith("https://")) {
            var afterScheme = href.substring(href.indexOf("://") + 3)
            var slashIdx    = afterScheme.indexOf("/")
            var host        = slashIdx >= 0 ? afterScheme.substring(0, slashIdx) : afterScheme
            // strip port
            var portIdx = host.lastIndexOf(":")
            if (portIdx > 0) host = host.substring(0, portIdx)
            return "https://" + host + "/favicon.ico"
        }
        return ""
    }

    function titleFromHref(href) {
        if (!href) return ""
        if (href.startsWith("http://") || href.startsWith("https://")) {
            var afterScheme = href.substring(href.indexOf("://") + 3)
            if (afterScheme.startsWith("www.")) afterScheme = afterScheme.substring(4)
            var slashIdx = afterScheme.indexOf("/")
            return slashIdx >= 0 ? afterScheme.substring(0, slashIdx) : afterScheme
        }
        if (href.startsWith("file://")) {
            var path      = decodeURIComponent(href.substring(7))
            var lastSlash = path.lastIndexOf("/")
            return lastSlash >= 0 ? path.substring(lastSlash + 1) : path
        }
        var lastSlash2 = href.lastIndexOf("/")
        return lastSlash2 >= 0 ? href.substring(lastSlash2 + 1) : href
    }

    // ── Load recently-used.xbel ───────────────────────────────────────────────
    function loadItems() {
        if (!root.appId) return
        // StandardPaths.writableLocation may return "file:///..." or a native path — normalise
        var rawPath = StandardPaths.writableLocation(StandardPaths.GenericDataLocation)
                      .toString().replace(/^file:\/\//, "")
        var xbelUrl = "file://" + rawPath + "/recently-used.xbel"
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 0 || xhr.status === 200) {
                    parseXBEL(xhr.responseText)
                }
            }
        }
        xhr.open("GET", xbelUrl)
        xhr.send()
    }

    function parseXBEL(text) {
        if (!text) return
        var items = []

        // Split on <bookmark openings — avoids heavyweight XML parsing
        var parts = text.split("<bookmark ")
        for (var i = 1; i < parts.length; i++) {
            var section = parts[i]

            // Trim everything after the closing </bookmark>
            var closeIdx = section.indexOf("</bookmark>")
            if (closeIdx >= 0) section = section.substring(0, closeIdx)

            // href
            var hrefM = /href="([^"]*)"/.exec(section)
            if (!hrefM) continue
            var href = hrefM[1]
                .replace(/&amp;/g,  "&")
                .replace(/&lt;/g,   "<")
                .replace(/&gt;/g,   ">")
                .replace(/&quot;/g, '"')
                .replace(/&apos;/g, "'")

            // Skip uninteresting protocols
            if (href.startsWith("appstream://") ||
                href.startsWith("apt://") ||
                href.startsWith("snap://")) continue

            // visited / modified timestamp for sorting
            var visitedM  = /visited="([^"]*)"/.exec(section)
            var modifiedM = /modified="([^"]*)"/.exec(section)
            var visited   = (visitedM ? visitedM[1] : "") || (modifiedM ? modifiedM[1] : "")

            // title
            var titleM = /<title>([^<]*)<\/title>/.exec(section)
            var title  = titleM ? titleM[1].trim() : ""
            if (!title) title = titleFromHref(href)

            // application match
            var appsM      = /<bookmark:applications>([\s\S]*?)<\/bookmark:applications>/.exec(section)
            var appMatches = false
            if (appsM) {
                var nameRe = /name="([^"]*)"/g
                var nameM2
                while ((nameM2 = nameRe.exec(appsM[1])) !== null) {
                    if (matchesApp(nameM2[1])) { appMatches = true; break }
                }
            }

            if (appMatches && href) {
                items.push({ href: href, title: title, visited: visited })
            }
        }

        // Sort newest-first
        items.sort(function (a, b) {
            if (a.visited > b.visited) return -1
            if (a.visited < b.visited) return  1
            return 0
        })

        // Build set of pinned hrefs for deduplication
        var pinnedSet = {}
        for (var j = 0; j < pinnedModel.count; j++) {
            pinnedSet[pinnedModel.get(j).href] = true
        }

        recentModel.clear()
        var count = 0
        for (var k = 0; k < items.length && count < root.maxRecentItems; k++) {
            if (!pinnedSet[items[k].href]) {
                recentModel.append(items[k])
                count++
            }
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    Component.onCompleted: {
        refreshPinned()
        loadItems()
    }

    onAppIdChanged: {
        if (root.appId) {
            refreshPinned()
            loadItems()
        }
    }

    Connections {
        target: Plasmoid.configuration
        function onPinnedRecentItemsChanged() {
            root.refreshPinned()
            root.loadItems()
        }
    }

    // ── Visual layout ─────────────────────────────────────────────────────────

    // Top separator line
    Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Kirigami.Theme.textColor
        opacity: 0.18
        Layout.topMargin:    Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing / 2
    }

    // ── ULUBIONE section ──────────────────────────────────────────────────────
    PlasmaComponents3.Label {
        visible: pinnedModel.count > 0
        text: Wrappers.i18n("Ulubione:")
        font.family:    Kirigami.Theme.smallFont.family
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        font.bold: true
        opacity: 0.75
        Layout.leftMargin: 2
        Layout.bottomMargin: 1
    }

    Repeater {
        model: pinnedModel

        delegate: ItemRow {
            required property string href
            required property string title

            Layout.fillWidth: true
            Layout.leftMargin:  2
            Layout.rightMargin: 2

            itemHref:       href
            itemTitle:      title
            itemFaviconUrl: root.faviconUrl(href)
            isPinned:       true

            onPinToggled:  root.togglePin(href, title)
            onItemClicked: Qt.openUrlExternally(href)
        }
    }

    // Separator between Ulubione and Ostatnie
    Item {
        visible: pinnedModel.count > 0 && recentModel.count > 0
        Layout.fillWidth: true
        height: Kirigami.Units.smallSpacing / 2
    }

    // ── OSTATNIE section ──────────────────────────────────────────────────────
    PlasmaComponents3.Label {
        visible: recentModel.count > 0
        text: Wrappers.i18n("Ostatnie:")
        font.family:    Kirigami.Theme.smallFont.family
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        font.bold: true
        opacity: 0.75
        Layout.leftMargin: 2
        Layout.bottomMargin: 1
    }

    Repeater {
        model: recentModel

        delegate: ItemRow {
            required property string href
            required property string title

            Layout.fillWidth: true
            Layout.leftMargin:  2
            Layout.rightMargin: 2

            itemHref:       href
            itemTitle:      title
            itemFaviconUrl: root.faviconUrl(href)
            isPinned:       false

            onPinToggled:  root.togglePin(href, title)
            onItemClicked: Qt.openUrlExternally(href)
        }
    }
}
