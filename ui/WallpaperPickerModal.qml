import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modals.Common
import qs.Widgets
import "../js/Utils.js" as Utils

// Unified wallpaper picker. One implementation serves both hosts:
//   - the daemon plugin opens it through IPC (picker / pickerMonitor)
//   - the settings page opens it for scene browse, playlist add and span browse
//
// Hosts bind the persisted state (namedPlaylists, namedPlaylistSettings,
// spanGroups, activePlaylistNames, currentSceneId, scrollPositions) and react
// to the signals; the picker never writes storage itself. Sections can be
// hidden for hosts that only need scene selection (showPlaylists/showSpanGroups).
//
// The picker always applies to a target owner: "*", a monitor name, or
// "span:<groupId>". Named playlists used on a target are copied into the
// target's rotation (monitor playlist or span group playlist).
DankModal {
    id: root

    property string targetOwner: "*"
    property string activeType: "scene"
    property string currentSceneId: ""
    property string steamWorkshopPath: ""
    property string customBackgroundsPath: ""
    property var namedPlaylists: ({})
    property var namedPlaylistSettings: ({})
    property var spanGroups: []
    // currently connected monitor names (host-fed); span groups with no
    // connected monitor are stale configs (e.g. docked-mode while undocked)
    // and render as offline in the sidebar
    property var connectedMonitors: []
    property var activePlaylistNames: ({})
    property var scrollPositions: ({})
    // host-provided accurate "what is rendering now" summary for the sidebar
    // CURRENT section (receives the target owner, returns a display string);
    // falls back to currentSceneId when the host does not provide one
    property var describeTarget: null
    // section visibility for hosts that only need scene selection
    property bool showPlaylists: true
    property bool showSpanGroups: true
    // hosts can relabel the primary action ("Apply" vs "Add to Playlist")
    property string applyLabel: "Apply"
    // hosts without an "all monitors" concept (the settings page has its own
    // monitor dropdown) can hide the apply-to-all secondary action
    property bool showApplyToAll: true

    // picker-local view state (never bound from the host)
    property string viewMode: "library" // "library" | "playlist" | "span"
    property string selectedSceneId: ""
    property string searchText: ""
    property string selectedPlaylistName: ""
    property string selectedSpanGroupId: ""
    property var playlistSceneIds: []
    property string addTargetKind: "named" // "named" | "span"
    property string addTargetKey: ""
    property bool scanning: false
    property int selectedIntervalMinutes: 5
    property bool selectedPlaylistShuffle: false

    readonly property bool sidebarVisible: showPlaylists || showSpanGroups
    readonly property bool targetIsSpan: Utils.ownerIsSpan(targetOwner)

    signal sceneApplied(string sceneId)
    signal sceneAppliedToAll(string sceneId)
    signal sceneAddedToPlaylist(string sceneId, string playlistName)
    signal sceneRemovedFromPlaylist(string sceneId, string playlistName)
    signal playlistCreated(string name)
    signal playlistDeleted(string name)
    signal playlistActivated(string name)
    signal playlistSettingsChanged(string name, int intervalMinutes, bool shuffle)
    signal spanGroupActivated(string groupId)
    signal spanSceneAdded(string groupId, string sceneId)
    signal spanSceneRemoved(string groupId, string sceneId)
    signal scrollPositionsSaved(var positions)

    modalWidth: Math.min(screenWidth - 80, 1180)
    modalHeight: Math.min(screenHeight - 80, 780)
    layerNamespace: "dms:plugins:linuxWallpaperEngine"
    useOverlayLayer: false
    width: modalWidth
    height: modalHeight
    positioning: "center"
    allowStacking: true

    onTargetOwnerChanged: refreshTargetState()

    onDialogClosed: {
        saveCurrentScrollPosition()
        scrollPositionsSaved(pendingScrollPositions !== null ? pendingScrollPositions : (scrollPositions || {}))
        pendingScrollPositions = null
        selectedSceneId = ""
        searchText = ""
        if (typeof searchField !== "undefined" && searchField)
            searchField.text = ""
    }

    // Every host save reassigns pluginData wholesale, so all data bindings
    // fire on every mutation regardless of which key changed. The old handler
    // revalidated selectedPlaylistName unconditionally and, in span views
    // (where it is ""), hijacked the grid with the first named playlist's
    // content. revalidateSelection() re-syncs the CURRENT view instead.
    onNamedPlaylistsChanged: {
        rebuildModels()
        revalidateSelection()
    }

    onNamedPlaylistSettingsChanged: loadSelectedViewSettings()
    onSpanGroupsChanged: {
        rebuildModels()
        revalidateSelection()
    }
    onActivePlaylistNamesChanged: rebuildModels()
    onPlaylistSceneIdsChanged: filterScenes()

    // assign playlistSceneIds only when the content actually changed, so
    // unrelated saves don't refilter the grid (and reset scroll) for nothing
    function setViewList(list) {
        const next = Array.isArray(list) ? list.slice() : []
        const current = Array.isArray(playlistSceneIds) ? playlistSceneIds : []
        if (Utils.deepEqual(next, current))
            return

        playlistSceneIds = next
    }

    // Re-sync the current view with fresh host data without switching views:
    // span views refresh from the group, playlist views from the named
    // playlist (falling back if the selection vanished), library just keeps
    // the add target valid.
    function revalidateSelection() {
        if (viewMode === "span") {
            const group = selectedSpanGroupId !== "" ? spanGroupById(selectedSpanGroupId) : null
            if (group === null) {
                showLibrary()
                return
            }
            setViewList(group.playlist)
            return
        }
        if (viewMode === "playlist") {
            if (selectedPlaylistName && namedPlaylists[selectedPlaylistName] !== undefined) {
                setViewList(namedPlaylists[selectedPlaylistName])
                loadSelectedViewSettings()
                return
            }
            const names = playlistNames()
            if (names.length > 0) {
                selectedPlaylistName = names[0]
                setViewList(namedPlaylists[names[0]])
                loadSelectedViewSettings()
                return
            }
            selectedPlaylistName = ""
            setViewList([])
            showLibrary()
            return
        }
        if (addTargetKey === "" || !addTargetValid())
            pickDefaultAddTarget()
    }

    function showLibrary() {
        saveCurrentScrollPosition()
        viewMode = "library"
        selectedSceneId = currentSceneId
        refreshTargetState()
        filterScenes()
        if (allScenes.count === 0)
            scanScenes()

        restoreScrollPosition("library")
    }

    function selectPlaylist(name) {
        if (!name || !namedPlaylists || namedPlaylists[name] === undefined)
            return

        saveCurrentScrollPosition()
        selectedSpanGroupId = ""
        selectedPlaylistName = name
        viewMode = "playlist"
        playlistSceneIds = Array.isArray(namedPlaylists[name]) ? namedPlaylists[name].slice() : []
        selectedSceneId = ""
        loadSelectedViewSettings()
        filterScenes()
        restoreScrollPosition("playlist:" + name)
    }

    function selectSpanGroup(groupId) {
        if (!groupId || spanGroupById(groupId) === null)
            return

        saveCurrentScrollPosition()
        selectedPlaylistName = ""
        selectedSpanGroupId = groupId
        viewMode = "span"
        const group = spanGroupById(groupId)
        playlistSceneIds = Array.isArray(group.playlist) ? group.playlist.slice() : []
        selectedSceneId = ""
        loadSelectedViewSettings()
        filterScenes()
        restoreScrollPosition("span:" + groupId)
    }

    // Resolve which named playlist the interval/shuffle row edits: the viewed
    // playlist in playlist view, or the playlist bound to the viewed span group.
    function settingsPlaylistName() {
        if (viewMode === "playlist")
            return selectedPlaylistName

        if (viewMode === "span") {
            const bound = (activePlaylistNames || {})["span:" + selectedSpanGroupId]
            return bound !== undefined ? bound : ""
        }
        return ""
    }

    function loadSelectedViewSettings() {
        const name = settingsPlaylistName()
        const settings = name !== "" ? ((namedPlaylistSettings || {})[name] || {}) : {}
        selectedIntervalMinutes = Math.max(0, Number(settings.intervalMinutes !== undefined ? settings.intervalMinutes : 5))
        selectedPlaylistShuffle = settings.shuffle === true
    }

    function updateSelectedPlaylistSettings(intervalMinutes, shuffle) {
        const name = settingsPlaylistName()
        if (name === "")
            return

        const interval = Math.max(0, Math.round(Number(intervalMinutes)))
        const random = shuffle === true
        if (selectedIntervalMinutes === interval && selectedPlaylistShuffle === random)
            return

        selectedIntervalMinutes = interval
        selectedPlaylistShuffle = random
        playlistSettingsChanged(name, interval, random)
    }

    function playlistNames() {
        return Object.keys(namedPlaylists || {}).sort(function (a, b) { return a.localeCompare(b) })
    }

    function spanGroupById(groupId) {
        const groups = Array.isArray(spanGroups) ? spanGroups : []
        for (let i = 0; i < groups.length; ++i) {
            if (groups[i].id === groupId)
                return groups[i]
        }
        return null
    }

    function spanGroupIsLive(groupId) {
        const group = spanGroupById(groupId)
        if (group === null)
            return false

        const monitors = Array.isArray(group.monitors) ? group.monitors : []
        const connected = Array.isArray(connectedMonitors) ? connectedMonitors : []
        for (let i = 0; i < monitors.length; ++i) {
            if (connected.indexOf(monitors[i]) >= 0)
                return true
        }
        return false
    }

    function spanGroupLabel(groupId) {
        const groups = Array.isArray(spanGroups) ? spanGroups : []
        for (let i = 0; i < groups.length; ++i) {
            if (groups[i].id === groupId)
                return "Group " + (i + 1)
        }
        return groupId ? groupId : "Group"
    }

    function targetLabel() {
        if (targetIsSpan)
            return "Span \u00b7 " + spanGroupLabel(Utils.spanGroupId(targetOwner))

        return targetOwner === "*" ? "All Monitors" : targetOwner
    }

    // Keep sidebar badges and the default add target in sync with the target.
    function refreshTargetState() {
        rebuildModels()
        if (viewMode === "span" && spanGroupById(selectedSpanGroupId) === null)
            showLibrary()

        if (addTargetKey === "" || !addTargetValid())
            pickDefaultAddTarget()
    }

    function addTargetValid() {
        if (addTargetKind === "span")
            return spanGroupById(addTargetKey) !== null

        return namedPlaylists !== null && namedPlaylists[addTargetKey] !== undefined
    }

    function pickDefaultAddTarget() {
        if (showPlaylists) {
            // prefer the named playlist bound to the target, then any playlist
            const bound = (activePlaylistNames || {})[targetOwner]
            if (bound !== undefined && namedPlaylists[bound] !== undefined) {
                setAddTarget("named", bound)
                return
            }
            const names = playlistNames()
            if (names.length > 0) {
                setAddTarget("named", names[0])
                return
            }
        }
        if (showSpanGroups) {
            const groups = Array.isArray(spanGroups) ? spanGroups : []
            if (groups.length > 0) {
                setAddTarget("span", groups[0].id)
                return
            }
        }
        addTargetKind = "named"
        addTargetKey = ""
    }

    function setAddTarget(kind, key) {
        if (kind === "span" && spanGroupById(key) === null)
            return

        if (kind === "named" && (namedPlaylists || {})[key] === undefined)
            return

        addTargetKind = kind
        addTargetKey = key
    }

    function addTargetLabel() {
        if (addTargetKind === "span")
            return "Span: " + spanGroupLabel(addTargetKey)

        return addTargetKey
    }

    function addTargetOptions() {
        const options = showPlaylists ? playlistNames() : []
        if (showSpanGroups) {
            const groups = Array.isArray(spanGroups) ? spanGroups : []
            for (let i = 0; i < groups.length; ++i)
                options.push("Span: " + spanGroupLabel(groups[i].id))
        }
        return options
    }

    function addTargetContains(sceneId) {
        if (!sceneId)
            return false

        if (addTargetKind === "span") {
            const group = spanGroupById(addTargetKey)
            const list = group ? group.playlist : []
            return Array.isArray(list) && list.indexOf(sceneId) >= 0
        }
        const list = (namedPlaylists || {})[addTargetKey]
        return Array.isArray(list) && list.indexOf(sceneId) >= 0
    }

    function createPlaylist() {
        const names = playlistNames()
        let index = 1
        let name = ""
        do {
            name = "Playlist " + index
            index++
        } while (names.indexOf(name) >= 0)

        // optimistically switch to the new view; the host persists through
        // playlistCreated() and the binding refresh revalidates the selection
        selectedSpanGroupId = ""
        selectedPlaylistName = name
        viewMode = "playlist"
        playlistSceneIds = []
        selectedSceneId = ""
        playlistCreated(name)
    }

    function applySelected() {
        if (!selectedSceneId)
            return

        sceneApplied(selectedSceneId)
        close()
    }

    function rebuildModels() {
        playlistModel.clear()
        const names = playlistNames()
        const activeName = (activePlaylistNames || {})[targetOwner] || ""
        for (const name of names) {
            const scenes = namedPlaylists[name]
            playlistModel.append({
                "playlistName": name,
                "sceneCount": Array.isArray(scenes) ? scenes.length : 0,
                "isActive": name === activeName
            })
        }

        spanModel.clear()
        const groups = Array.isArray(spanGroups) ? spanGroups : []
        const spanActiveType = activeType === "span"
        for (let i = 0; i < groups.length; ++i) {
            const g = groups[i]
            const live = spanGroupIsLive(g.id)
            spanModel.append({
                "groupId": g.id,
                "groupLabel": "Group " + (i + 1),
                "sceneCount": Array.isArray(g.playlist) ? g.playlist.length : 0,
                "isLive": live,
                "isActive": live && (spanActiveType || ((activePlaylistNames || {})["span:" + g.id] !== undefined))
            })
        }
    }

    function scanScenes() {
        const source = customBackgroundsPath || steamWorkshopPath
        if (!source || scanning)
            return

        scanning = true
        allScenes.clear()
        filteredScenes.clear()
        scanProcess.output = ""
        const script = 'src="$1"; cd "$src" 2>/dev/null || exit 0; for dir in */; do id="${dir%/}"; [[ -f "$id/project.json" ]] || continue; title=$(jq -r \'.title // empty\' "$id/project.json" 2>/dev/null); [[ -n "$title" ]] || title="$id"; printf "%s|%s\\n" "$id" "$title"; done'
        scanProcess.command = ["bash", "-c", script, "bash", source]
        scanProcess.running = true
    }

    function currentViewKey() {
        if (viewMode === "playlist" && selectedPlaylistName)
            return "playlist:" + selectedPlaylistName

        if (viewMode === "span" && selectedSpanGroupId)
            return "span:" + selectedSpanGroupId

        return "library"
    }

    // scrollPositions is a host-fed input the picker never assigns (assigning
    // would break the host binding); edits accumulate in a working copy that
    // is emitted on close and re-seeded from the host on next open
    property var pendingScrollPositions: null

    function scrollStore() {
        if (pendingScrollPositions === null)
            pendingScrollPositions = Object.assign({}, scrollPositions || {})
        return pendingScrollPositions
    }

    function saveCurrentScrollPosition() {
        if (typeof sceneGrid === "undefined" || !sceneGrid)
            return

        const positions = scrollStore()
        positions[currentViewKey()] = Math.max(0, sceneGrid.contentY)
    }

    // a 0ms timer lets the grid lay out before clamping, unlike a single
    // callLater which can run while contentHeight is still stale
    function restoreScrollPosition(key) {
        const source = pendingScrollPositions !== null ? pendingScrollPositions : (scrollPositions || {})
        scrollRestoreTimer.pendingY = Number(source[key] || 0)
        scrollRestoreTimer.restart()
    }

    function filterScenes() {
        // sceneGrid lives inside the lazily-loaded modal content; host entry
        // points may run before it is instantiated
        const haveGrid = typeof sceneGrid !== "undefined" && sceneGrid
        const keepY = haveGrid ? sceneGrid.contentY : 0
        const keepKey = currentViewKey()
        filteredScenes.clear()
        const term = searchText.toLowerCase()
        const playlist = Array.isArray(playlistSceneIds) ? playlistSceneIds : []
        for (let i = 0; i < allScenes.count; ++i) {
            const scene = allScenes.get(i)
            if (viewMode !== "library" && playlist.indexOf(scene.sceneId) < 0)
                continue

            if (term && scene.sceneId.toLowerCase().indexOf(term) < 0 && String(scene.name || "").toLowerCase().indexOf(term) < 0)
                continue

            filteredScenes.append({
                "sceneId": scene.sceneId,
                "name": scene.name
            })
        }
        if (haveGrid && keepKey === lastFilterKey && keepY > 0)
            sceneGrid.contentY = keepY

        lastFilterKey = keepKey
    }

    property string lastFilterKey: ""

    function intervalValue(label) {
        return label === "Manual" ? 0 : parseInt(label, 10)
    }

    function intervalOptions() {
        const labels = ["Manual", "1 min", "2 min", "5 min", "10 min", "15 min", "30 min", "60 min"]
        const value = Math.max(0, Math.round(selectedIntervalMinutes))
        const label = value === 0 ? "Manual" : value + " min"
        if (labels.indexOf(label) < 0) {
            labels.push(label)
            labels.sort(function (a, b) { return intervalValue(a) - intervalValue(b) })
        }
        return labels
    }

    function intervalLabel() {
        const value = Math.max(0, Math.round(selectedIntervalMinutes))
        return value === 0 ? "Manual" : value + " min"
    }

    ListModel {
        id: allScenes
    }

    ListModel {
        id: filteredScenes
    }

    ListModel {
        id: playlistModel
    }

    ListModel {
        id: spanModel
    }

    Timer {
        id: scrollRestoreTimer

        property real pendingY: 0

        interval: 0
        repeat: false
        onTriggered: {
            // the modal content may not be instantiated yet on a pre-open call
            if (typeof sceneGrid === "undefined" || !sceneGrid)
                return

            const maxY = Math.max(0, sceneGrid.contentHeight - sceneGrid.height)
            sceneGrid.contentY = Math.max(0, Math.min(maxY, pendingY))
        }
    }

    Process {
        id: scanProcess

        property string output: ""

        stdout: SplitParser {
            onRead: (data) => {
                scanProcess.output += data + "\n"
            }
        }

        onExited: (code) => {
            if (code === 0 && output) {
                const lines = output.trim().split("\n")
                for (const line of lines) {
                    const trimmed = line.trim()
                    const split = trimmed.indexOf("|")
                    if (trimmed && split > 0) {
                        allScenes.append({
                            "sceneId": trimmed.slice(0, split),
                            "name": trimmed.slice(split + 1)
                        })
                    }
                }
            }
            scanning = false
            filterScenes()
            restoreScrollPosition(currentViewKey())
            output = ""
        }
    }

    content: Rectangle {
        anchors.fill: parent
        color: Theme.surface

        Rectangle {
            id: header

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 62
            color: Theme.surfaceContainer

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingL
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingM

                DankIcon {
                    name: "wallpaper"
                    size: Theme.iconSize
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Wallpaper Engine"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    height: 28
                    radius: height / 2
                    color: Theme.surfaceContainerHighest
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.targetLabel() !== ""

                    StyledText {
                        anchors.centerIn: parent
                        anchors.margins: Theme.spacingS
                        text: root.targetLabel()
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }

            DankButton {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingL
                anchors.verticalCenter: parent.verticalCenter
                text: "Close"
                onClicked: root.close()
            }
        }

        Rectangle {
            id: sidebar

            anchors.left: parent.left
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            width: root.sidebarVisible ? 224 : 0
            visible: root.sidebarVisible
            color: Theme.surfaceContainerLow

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                NavItem {
                    width: parent.width
                    iconName: "grid_view"
                    label: "All Scenes"
                    detail: allScenes.count + ""
                    active: root.viewMode === "library"
                    onActivated: root.showLibrary()
                }

                StyledText {
                    width: parent.width
                    text: "PLAYLISTS"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.55
                    visible: root.showPlaylists
                }

                DankButton {
                    width: parent.width
                    text: "+  New Playlist"
                    visible: root.showPlaylists
                    onClicked: root.createPlaylist()
                }

                Repeater {
                    model: playlistModel

                    delegate: NavItem {
                        required property string playlistName
                        required property int sceneCount
                        required property bool isActive

                        width: parent.width
                        iconName: isActive ? "play_arrow" : "playlist_play"
                        label: playlistName
                        detail: sceneCount + ""
                        active: root.viewMode === "playlist" && root.selectedPlaylistName === playlistName
                        onActivated: root.selectPlaylist(playlistName)
                        onDoubleActivated: {
                            const list = root.namedPlaylists[playlistName]
                            if (Array.isArray(list) && list.length > 0) {
                                root.playlistActivated(playlistName)
                                root.close()
                            }
                        }
                    }
                }

                Item {
                    width: 1
                    height: Theme.spacingS
                    visible: root.showSpanGroups
                }

                StyledText {
                    width: parent.width
                    text: "SPAN GROUPS"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.55
                    visible: root.showSpanGroups
                }

                Repeater {
                    model: spanModel

                    delegate: NavItem {
                        required property string groupId
                        required property string groupLabel
                        required property int sceneCount
                        required property bool isLive
                        required property bool isActive

                        width: parent.width
                        iconName: isActive ? "play_arrow" : "monitor"
                        label: groupLabel
                        detail: isLive ? sceneCount + "" : "offline"
                        dimmed: !isLive
                        active: root.viewMode === "span" && root.selectedSpanGroupId === groupId
                        onActivated: root.selectSpanGroup(groupId)
                        onDoubleActivated: {
                            const group = root.spanGroupById(groupId)
                            const list = group ? group.playlist : []
                            if (Array.isArray(list) && list.length > 0) {
                                root.spanGroupActivated(groupId)
                                root.close()
                            }
                        }
                    }
                }

                Item {
                    width: 1
                    height: Theme.spacingS
                }

                StyledText {
                    width: parent.width
                    text: "CURRENT"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.55
                }

                StyledText {
                    width: parent.width
                    text: {
                        if (root.describeTarget !== null)
                            return root.describeTarget(root.targetOwner)

                        return root.currentSceneId || "No active scene"
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.8
                    wrapMode: Text.WrapAnywhere
                }
            }
        }

        Item {
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            anchors.margins: Theme.spacingL

            DankTextField {
                id: searchField

                anchors.left: parent.left
                anchors.right: refreshButton.left
                anchors.rightMargin: Theme.spacingM
                anchors.top: parent.top
                placeholderText: {
                    if (root.viewMode === "playlist")
                        return "Search " + root.selectedPlaylistName + "..."

                    if (root.viewMode === "span")
                        return "Search " + root.spanGroupLabel(root.selectedSpanGroupId) + "..."

                    return "Search scenes..."
                }
                onTextChanged: {
                    root.searchText = text
                    root.filterScenes()
                }
            }

            DankButton {
                id: refreshButton

                anchors.right: parent.right
                anchors.top: parent.top
                text: root.scanning ? "Scanning..." : "Refresh"
                enabled: !root.scanning
                onClicked: root.scanScenes()
            }

            StyledText {
                id: statusText

                anchors.left: parent.left
                anchors.top: playlistSettingsRow.visible ? playlistSettingsRow.bottom : searchField.bottom
                anchors.topMargin: Theme.spacingS
                text: {
                    const total = filteredScenes.count
                    if (root.scanning)
                        return "Scanning scene library..."

                    if (!total)
                        return "No scenes"

                    const row = Math.max(0, Math.floor(sceneGrid.contentY / sceneGrid.cellHeight))
                    const first = Math.min(total, row * sceneGrid.columns + 1)
                    const rows = Math.ceil(sceneGrid.height / sceneGrid.cellHeight)
                    const last = Math.min(total, first + rows * sceneGrid.columns - 1)
                    return first + "-" + last + " of " + total
                }
                font.pixelSize: Theme.fontSizeSmall
                opacity: 0.65
            }

            Row {
                id: playlistSettingsRow

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: searchField.bottom
                anchors.topMargin: Theme.spacingS
                height: visible ? 40 : 0
                // span groups without a bound named playlist rotate on the
                // global defaults; there is nothing per-group to edit yet
                visible: root.settingsPlaylistName() !== ""
                spacing: Theme.spacingM

                StyledText {
                    text: "Switch every"
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankDropdown {
                    width: 130
                    options: root.intervalOptions()
                    currentValue: root.intervalLabel()
                    compactMode: true
                    transientSurfaceTracker: root.transientSurfaceTracker
                    onValueChanged: (value) => {
                        root.updateSelectedPlaylistSettings(root.intervalValue(value), root.selectedPlaylistShuffle)
                    }
                }

                Item {
                    width: Theme.spacingL
                    height: 1
                }

                StyledText {
                    text: "Shuffle"
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankToggle {
                    id: playlistShuffleToggle

                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.updateSelectedPlaylistSettings(root.selectedIntervalMinutes, checked)

                    Binding {
                        target: playlistShuffleToggle
                        property: "checked"
                        value: root.selectedPlaylistShuffle
                    }
                }
            }

            Rectangle {
                id: gridFrame

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: statusText.bottom
                anchors.topMargin: Theme.spacingS
                anchors.bottom: actions.top
                anchors.bottomMargin: Theme.spacingM
                color: Theme.surfaceContainerLow
                radius: Theme.cornerRadius
                clip: true

                GridView {
                    id: sceneGrid

                    // imperative on purpose: a plain binding evaluated against the
                    // pre-layout width inside the lazily created modal content left
                    // the count stale on some hosts; recompute on every resize
                    property int columns: 6

                    function recomputeColumns() {
                        columns = Math.max(3, Math.floor(width / 150))
                    }

                    onWidthChanged: recomputeColumns()
                    Component.onCompleted: recomputeColumns()

                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM + 14
                    clip: true
                    model: filteredScenes
                    boundsBehavior: Flickable.StopAtBounds
                    flickDeceleration: 3500
                    maximumFlickVelocity: 9000
                    keyNavigationEnabled: true
                    // integer cell sizes: fractional widths force non-integer
                    // preview textures (MultiEffect per card) and leave visible
                    // end-of-row gaps on some scale factors
                    cellWidth: columns > 0 ? Math.floor(width / columns) : Math.floor(width)
                    cellHeight: cellWidth + 54

                    delegate: Item {
                        id: delegateRoot

                        required property var modelData
                        property var scene: modelData || ({})

                        width: sceneGrid.cellWidth
                        height: sceneGrid.cellHeight

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            radius: Theme.cornerRadius
                            color: cardMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                            border.width: root.selectedSceneId === delegateRoot.scene.sceneId ? 2 : 0
                            border.color: Theme.primary

                            Column {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                ScenePreview {
                                    width: parent.width
                                    height: width
                                    roundedMask: true
                                    animate: cardMouse.containsMouse && !sceneGrid.moving
                                    fallbackText: "No Preview"
                                    sceneId: delegateRoot.scene.sceneId || ""
                                    steamWorkshopPath: root.steamWorkshopPath
                                    backgroundsDir: root.customBackgroundsPath
                                }

                                StyledText {
                                    width: parent.width
                                    text: delegateRoot.scene.name || delegateRoot.scene.sceneId || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: delegateRoot.scene.sceneId || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    opacity: 0.55
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                id: cardMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.selectedSceneId = delegateRoot.scene.sceneId || ""
                                onDoubleClicked: {
                                    root.selectedSceneId = delegateRoot.scene.sceneId || ""
                                    root.applySelected()
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: scrollTrack

                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingM
                    width: 8
                    radius: 4
                    color: Theme.surfaceContainerHighest
                    visible: sceneGrid.contentHeight > sceneGrid.height

                    Rectangle {
                        id: scrollThumb

                        width: parent.width
                        height: Math.max(40, parent.height * sceneGrid.visibleArea.heightRatio)
                        y: Math.min(parent.height - height, parent.height * sceneGrid.visibleArea.yPosition)
                        radius: 4
                        color: scrollMouse.containsMouse || scrollMouse.pressed ? Theme.primary : Theme.outline
                    }

                    MouseArea {
                        id: scrollMouse

                        function seek(yPos) {
                            const maxY = Math.max(0, sceneGrid.contentHeight - sceneGrid.height)
                            const travel = Math.max(1, height - scrollThumb.height)
                            sceneGrid.contentY = maxY * Math.max(0, Math.min(1, (yPos - scrollThumb.height / 2) / travel))
                        }

                        anchors.fill: parent
                        hoverEnabled: true
                        onPressed: (mouse) => seek(mouse.y)
                        onPositionChanged: (mouse) => {
                            if (pressed)
                                seek(mouse.y)
                        }
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: !root.scanning && filteredScenes.count === 0
                    text: root.viewMode === "library" ? "No scenes found" : "Nothing here yet"
                    opacity: 0.6
                }
            }

            Item {
                id: actions

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: actionButtons.height

                StyledText {
                    anchors.left: parent.left
                    anchors.right: actionButtons.left
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.selectedSceneId ? root.selectedSceneId : "Select a scene"
                    elide: Text.ElideRight
                    opacity: root.selectedSceneId ? 0.8 : 0.5
                }

                Row {
                    id: actionButtons

                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: Theme.spacingS

                    DankButton {
                        text: root.selectedPlaylistName ? "Delete " + root.selectedPlaylistName : "Delete Playlist"
                        visible: root.viewMode === "playlist" && root.showPlaylists
                        enabled: root.selectedPlaylistName !== "Default" && root.playlistNames().length > 1
                        onClicked: root.playlistDeleted(root.selectedPlaylistName)
                    }

                    DankButton {
                        text: root.viewMode === "span" ? "Use Span Group" : "Use Playlist"
                        visible: root.viewMode === "playlist" || root.viewMode === "span"
                        enabled: root.playlistSceneIds.length > 0
                        onClicked: {
                            if (root.viewMode === "span")
                                root.spanGroupActivated(root.selectedSpanGroupId)
                            else
                                root.playlistActivated(root.selectedPlaylistName)
                            root.close()
                        }
                    }

                    DankDropdown {
                        width: 170
                        visible: root.viewMode === "library" && root.addTargetOptions().length > 0
                        options: root.addTargetOptions()
                        currentValue: root.addTargetLabel()
                        compactMode: true
                        openUpwards: true
                        transientSurfaceTracker: root.transientSurfaceTracker
                        onValueChanged: (value) => {
                            if (value.indexOf("Span: ") === 0) {
                                const label = value.slice(6)
                                const groups = Array.isArray(root.spanGroups) ? root.spanGroups : []
                                for (let i = 0; i < groups.length; ++i) {
                                    if (root.spanGroupLabel(groups[i].id) === label) {
                                        root.setAddTarget("span", groups[i].id)
                                        return
                                    }
                                }
                            } else {
                                root.setAddTarget("named", value)
                            }
                        }
                    }

                    DankButton {
                        text: root.viewMode === "library" ? "Add" : "Remove"
                        visible: root.viewMode === "library" ? root.addTargetOptions().length > 0 : true
                        enabled: {
                            if (root.selectedSceneId === "")
                                return false
                            if (root.viewMode === "library")
                                return root.addTargetValid() && !root.addTargetContains(root.selectedSceneId)
                            return true
                        }
                        onClicked: {
                            if (root.viewMode === "playlist") {
                                root.sceneRemovedFromPlaylist(root.selectedSceneId, root.selectedPlaylistName)
                            } else if (root.viewMode === "span") {
                                root.spanSceneRemoved(root.selectedSpanGroupId, root.selectedSceneId)
                            } else if (root.addTargetKind === "span") {
                                root.spanSceneAdded(root.addTargetKey, root.selectedSceneId)
                            } else {
                                root.sceneAddedToPlaylist(root.selectedSceneId, root.addTargetKey)
                            }
                        }
                    }

                    DankButton {
                        text: "Apply to All"
                        visible: root.showApplyToAll
                        enabled: root.selectedSceneId !== ""
                        onClicked: {
                            root.sceneAppliedToAll(root.selectedSceneId)
                            root.close()
                        }
                    }

                    DankButton {
                        text: root.applyLabel
                        enabled: root.selectedSceneId !== ""
                        onClicked: root.applySelected()
                    }
                }
            }
        }
    }

    component NavItem: Rectangle {
        id: nav

        property string iconName: ""
        property string label: ""
        property string detail: ""
        property bool active: false
        property bool dimmed: false

        signal activated()
        signal doubleActivated()

        height: 44
        radius: Theme.cornerRadius
        opacity: dimmed ? 0.45 : 1.0
        color: active ? Theme.primaryContainer : (navMouse.containsMouse ? Theme.surfaceContainerHighest : "transparent")

        DankIcon {
            id: navIcon

            name: nav.iconName
            size: Theme.iconSizeSmall
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            anchors.left: navIcon.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: navDetail.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: nav.label
            elide: Text.ElideRight
        }

        StyledText {
            id: navDetail

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            text: nav.detail
            opacity: 0.55
        }

        MouseArea {
            id: navMouse

            anchors.fill: parent
            hoverEnabled: true
            onClicked: nav.activated()
            onDoubleClicked: nav.doubleActivated()
        }
    }
}
