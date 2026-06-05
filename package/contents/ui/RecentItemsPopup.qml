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

    property var  pendingArgs: null
    property bool pendingOpen:  false   // czekamy na async — po wyniku otwieramy popup
    property int  pendingLoadCount: 0

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
    readonly property int maxActions: 8
    readonly property var fileManagerIds: ["org.kde.dolphin", "org.kde.krusader", "org.gnome.nautilus", "pcmanfm", "nemo", "thunar", "doublecmd"]
    readonly property bool isVSCode: {
        var a = popup.appId.toLowerCase()
        return a === "code" || a === "code-oss" || a === "vscodium"
            || a === "com.visualstudio.code" || a === "com.vscodium.codium"
            || a.indexOf("vscode") >= 0
    }

    // DataSource do otwierania elementów (np. code <path>)
    Plasma5Support.DataSource {
        id: openSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
        }
    }

    // Async: python3 get-history.py --app <appId> --limit N
    Plasma5Support.DataSource {
        id: historySource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = (data && data["stdout"]) || ""
            disconnectSource(sourceName)
            recentModel.clear()
            try {
                var entries = JSON.parse(stdout)
                var pinnedSet = {}
                for (var p = 0; p < pinnedModel.count; p++)
                    pinnedSet[pinnedModel.get(p).href] = true
                var count = 0
                for (var i = 0; i < entries.length && count < popup.maxRecent; i++) {
                    var e = entries[i]
                    if (e.url && !pinnedSet[e.url]) {
                        recentModel.append({
                            href:   e.url,
                            title:  e.title || popup.titleFor(e.url),
                            pinned: false,
                            icon:   e.icon || ""
                        })
                        count++
                    }
                }
            } catch(err) {
                console.warn("FancyTasks: get-history parse error:", err)
            }
            popup.finishOneAsyncLoad()
        }
    }

    // Async: python3 get-launch-actions.py --app <appId> --list
    Plasma5Support.DataSource {
        id: launchActionsSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = (data && data["stdout"]) || ""
            disconnectSource(sourceName)

            launchActionsModel.clear()
            try {
                var entries = JSON.parse(stdout)
                for (var i = 0; i < entries.length && i < popup.maxActions; i++) {
                    var e = entries[i]
                    if (!e || !e.id) continue
                    launchActionsModel.append({
                        actionId: e.id,
                        text: e.text || e.id
                    })
                }
            } catch(err) {
                console.warn("FancyTasks: get-launch-actions parse error:", err)
            }

            popup.finishOneAsyncLoad()
        }
    }

    // Async: python3 get-launch-actions.py --app <appId> --run <actionId>
    Plasma5Support.DataSource {
        id: runActionSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
        }
    }

    component ItemRow: Item {
        id: row

        required property string href
        required property string title
        required property bool   pinned
        required property string icon

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
            onTapped:    { popup.openHref(row.href); popup.close() }
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
                        if (row.icon && row.icon !== "")
                            return row.icon
                        return "folder"
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

    component ActionRow: Item {
        id: actionRow

        required property string actionId
        required property string text

        implicitHeight: actionRowLayout.implicitHeight + Kirigami.Units.smallSpacing * 2
        implicitWidth:  actionRowLayout.implicitWidth

        HoverHandler { id: actionHover }

        Rectangle {
            anchors { fill: parent; margins: -1 }
            color:   Kirigami.Theme.highlightColor
            opacity: actionHover.hovered ? 0.15 : 0.0
            radius:  3
            z:       -1
            Behavior on opacity { NumberAnimation { duration: 80 } }
        }

        TapHandler {
            cursorShape: Qt.PointingHandCursor
            onTapped: {
                popup.runLaunchAction(actionRow.actionId)
                popup.close()
            }
        }

        RowLayout {
            id: actionRowLayout
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
                source: "system-run"
            }

            PlasmaComponents3.Label {
                Layout.fillWidth:  true
                Layout.alignment:  Qt.AlignVCenter
                text:              actionRow.text
                elide:             Text.ElideRight
                font.family:    Kirigami.Theme.smallFont.family
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight:    Font.Normal
                font.bold:      false
            }
        }
    }

    mainItem: Item {
        implicitWidth:  320
        implicitHeight: contentCol.implicitHeight

        // ListModels here — not at Dialog level (defaultProperty = QQuickItem*)
        ListModel { id: pinnedModel }
        ListModel { id: recentModel }
        ListModel { id: launchActionsModel }

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

            PlasmaComponents3.Label {
                visible:             launchActionsModel.count > 0
                Layout.fillWidth:    true
                Layout.leftMargin:   Kirigami.Units.smallSpacing
                Layout.topMargin:    (pinnedModel.count > 0 || recentModel.count > 0) ? Kirigami.Units.smallSpacing : Kirigami.Units.smallSpacing / 2
                Layout.bottomMargin: 2
                text:                Wrappers.i18n("Akcje:")
                font.bold:           true
                font.family:         Kirigami.Theme.smallFont.family
                font.pointSize:      Kirigami.Theme.smallFont.pointSize
                opacity:             0.7
            }

            Repeater {
                model: launchActionsModel
                delegate: ActionRow {
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

    function openHref(href) {
        if (popup.isVSCode) {
            var cmd
            if (href.startsWith("vscode-remote://")) {
                // Zdalne repozytorium SSH / WSL itp.
                cmd = "code --folder-uri " + href
            } else if (href.startsWith("file://")) {
                var path = decodeURIComponent(href.substring(7))
                cmd = "code " + JSON.stringify(path)
            } else {
                Qt.openUrlExternally(href)
                return
            }
            openSource.connectSource(cmd)
        } else {
            Qt.openUrlExternally(href)
        }
    }

    // Wejście: wywoływane przez Task.qml przy prawym kliknięciu
    function beginLoad(contextMenuArgs) {
        if (!popup.appId) return
        pendingArgs = contextMenuArgs
        recentModel.clear()
        launchActionsModel.clear()
        doRefreshPinned()

        // New request: clear previous async processes to avoid stale callbacks.
        while (historySource.connectedSources.length > 0) {
            historySource.disconnectSource(historySource.connectedSources[0])
        }
        while (launchActionsSource.connectedSources.length > 0) {
            launchActionsSource.disconnectSource(launchActionsSource.connectedSources[0])
        }

        pendingLoadCount = 2
        popup.pendingOpen = (pinnedModel.count === 0)

        if (pinnedModel.count > 0) {
            // Pokaż popup od razu z ulubionymi; ostatnie wczytają się async
            popup.visible = true
        }

        loadAppHistoryAsync()
        loadLaunchActionsAsync()
    }

    // Kompatybilność wsteczna — tryLoad nie jest już używane przez Task.qml
    function tryLoad(contextMenuArgs) {
        beginLoad(contextMenuArgs)
        return false
    }

    function loadAppHistoryAsync() {
        var scriptPath = Qt.resolvedUrl("../code/get-history.py").toString().replace(/^file:\/\//, "")
        historySource.connectSource(
            "python3 " + JSON.stringify(scriptPath) + " --app " + JSON.stringify(popup.appId) + " --limit " + (popup.maxRecent + 5)
        )
    }

    function loadLaunchActionsAsync() {
        var scriptPath = Qt.resolvedUrl("../code/get-launch-actions.py").toString().replace(/^file:\/\//, "")
        launchActionsSource.connectSource(
            "python3 " + JSON.stringify(scriptPath) + " --app " + JSON.stringify(popup.appId) + " --list"
        )
    }

    function runLaunchAction(actionId) {
        if (!actionId) return
        var scriptPath = Qt.resolvedUrl("../code/get-launch-actions.py").toString().replace(/^file:\/\//, "")
        runActionSource.connectSource(
            "python3 " + JSON.stringify(scriptPath) + " --app " + JSON.stringify(popup.appId) + " --run " + JSON.stringify(actionId)
        )
    }

    function finishOneAsyncLoad() {
        if (pendingLoadCount > 0) {
            pendingLoadCount--
        }
        if (pendingLoadCount > 0 || !popup.pendingOpen) {
            return
        }

        popup.pendingOpen = false
        if (pinnedModel.count > 0 || recentModel.count > 0 || launchActionsModel.count > 0) {
            popup.visible = true
        } else {
            // Brak wyników — otwórz standardowe menu KDE
            popup.moreOptionsRequested()
        }
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
        if (href.startsWith("file://")) {
            var path      = decodeURIComponent(href.substring(7))
            var lastSlash = path.lastIndexOf("/")
            return lastSlash >= 0 ? path.substring(lastSlash + 1) : path
        }
        return href
    }

    function doRefreshPinned() {
        pinnedModel.clear()
        var list   = Plasmoid.configuration.pinnedRecentItems || []
        var prefix = popup.appId + "|"
        for (var i = 0; i < list.length; i++) {
            if (!list[i].startsWith(prefix)) continue
            var rest  = list[i].substring(prefix.length)
            var sep   = rest.indexOf("|")
            var href  = sep >= 0 ? rest.substring(0, sep)  : rest
            var title = sep >= 0 ? rest.substring(sep + 1) : titleFor(href)
            if (href) pinnedModel.append({ href: href, title: title || titleFor(href), pinned: true, icon: "" })
        }
    }

    function doTogglePin(href, title) {
        var key     = popup.appId + "|" + href + "|" + title.replace(/\|/g, " ")
        var current = Plasmoid.configuration.pinnedRecentItems || []
        var newList = []
        var found   = false
        for (var i = 0; i < current.length; i++) {
            if (current[i] === key) { found = true } else { newList.push(current[i]) }
        }
        if (!found) newList.push(key)
        Plasmoid.configuration.pinnedRecentItems = newList
        doRefreshPinned()
        loadAppHistoryAsync()
    }
}
