import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modals.Common
import qs.Widgets

DankModal {
    id: root

    property string steamWorkshopPath: ""
    property string customBackgroundsPath: ""
    property string currentSceneId: ""
    property string selectedSceneId: ""
    property string searchText: ""
    property string selectedPlaylistName: ""
    property string activePlaylistName: ""
    property var namedPlaylists: ({
    })
    property var namedPlaylistSettings: ({
    })
    property var scrollPositions: ({
    })
    property var playlistSceneIds: []
    property bool playlistView: false
    property bool scanning: false
    property int selectedIntervalMinutes: 5
    property bool selectedPlaylistShuffle: false

    signal sceneApplied(string sceneId)
    signal sceneAddedToPlaylist(string sceneId, string playlistName)
    signal sceneRemovedFromPlaylist(string sceneId, string playlistName)
    signal playlistCreated(string name)
    signal playlistDeleted(string name)
    signal playlistActivated(string name)
    signal playlistSettingsChanged(string name, int intervalMinutes, bool shuffle)
    signal scrollPositionsSaved(var positions)

    function showLibrary() {
        saveCurrentScrollPosition();
        playlistView = false;
        selectedSceneId = currentSceneId;
        filterScenes();
        if (allScenes.count === 0)
            scanScenes();

        restoreScrollPosition("library");
    }

    function playlistNames() {
        return Object.keys(namedPlaylists || {
        }).sort((a, b) => {
            return a.localeCompare(b);
        });
    }

    function selectPlaylist(name) {
        if (!name || !namedPlaylists || namedPlaylists[name] === undefined)
            return ;

        saveCurrentScrollPosition();
        selectedPlaylistName = name;
        playlistSceneIds = Array.isArray(namedPlaylists[name]) ? namedPlaylists[name].slice() : [];
        loadSelectedPlaylistSettings();
        playlistView = true;
        selectedSceneId = "";
        filterScenes();
        restoreScrollPosition("playlist:" + name);
    }

    function loadSelectedPlaylistSettings() {
        const settings = (namedPlaylistSettings || {
        })[selectedPlaylistName] || {
        };
        selectedIntervalMinutes = Math.max(0, Number(settings.intervalMinutes !== undefined ? settings.intervalMinutes : 5));
        selectedPlaylistShuffle = settings.shuffle === true;
    }

    function updateSelectedPlaylistSettings(intervalMinutes, shuffle) {
        if (!selectedPlaylistName)
            return ;

        const interval = Math.max(0, Number(intervalMinutes));
        const random = shuffle === true;
        if (selectedIntervalMinutes === interval && selectedPlaylistShuffle === random)
            return ;

        selectedIntervalMinutes = interval;
        selectedPlaylistShuffle = random;
        const allSettings = Object.assign({
        }, namedPlaylistSettings || {
        });
        allSettings[selectedPlaylistName] = {
            "intervalMinutes": interval,
            "shuffle": random
        };
        namedPlaylistSettings = allSettings;
        playlistSettingsChanged(selectedPlaylistName, interval, random);
    }

    function setAddTarget(name) {
        if (!name || namedPlaylists[name] === undefined)
            return ;

        selectedPlaylistName = name;
        playlistSceneIds = Array.isArray(namedPlaylists[name]) ? namedPlaylists[name].slice() : [];
    }

    function currentViewKey() {
        return playlistView && selectedPlaylistName ? "playlist:" + selectedPlaylistName : "library";
    }

    function saveCurrentScrollPosition() {
        if (typeof sceneGrid === "undefined" || !sceneGrid)
            return ;

        const positions = Object.assign({
        }, scrollPositions || {
        });
        positions[currentViewKey()] = Math.max(0, sceneGrid.contentY);
        scrollPositions = positions;
    }

    function restoreScrollPosition(key) {
        const value = Number((scrollPositions || {
        })[key] || 0);
        Qt.callLater(() => {
            const maxY = Math.max(0, sceneGrid.contentHeight - sceneGrid.height);
            sceneGrid.contentY = Math.max(0, Math.min(maxY, value));
        });
    }

    function createPlaylist() {
        let index = 1;
        let name = "";
        do {
            name = "Playlist " + index;
            index++;
        } while (namedPlaylists[name] !== undefined)
        if (namedPlaylists[name] !== undefined)
            return ;

        console.info("WallpaperPicker: Creating playlist", name);
        const updated = Object.assign({
        }, namedPlaylists);
        updated[name] = [];
        namedPlaylists = updated;
        selectedPlaylistName = name;
        playlistSceneIds = [];
        playlistView = true;
        selectedSceneId = "";
        rebuildPlaylistModel();
        filterScenes();
        playlistCreated(name);
    }

    function sceneInPlaylist(sceneId) {
        return sceneId && Array.isArray(playlistSceneIds) && playlistSceneIds.indexOf(sceneId) >= 0;
    }

    function applySelected() {
        if (!selectedSceneId)
            return ;

        currentSceneId = selectedSceneId;
        console.info("WallpaperPicker: Applying selected scene", selectedSceneId);
        sceneApplied(selectedSceneId);
        close();
    }

    function rebuildPlaylistModel() {
        playlistModel.clear();
        const names = playlistNames();
        for (const name of names) {
            const scenes = namedPlaylists[name];
            playlistModel.append({
                "playlistName": name,
                "sceneCount": Array.isArray(scenes) ? scenes.length : 0
            });
        }
    }

    function scanScenes() {
        const source = customBackgroundsPath || steamWorkshopPath;
        if (!source || scanning)
            return ;

        scanning = true;
        allScenes.clear();
        filteredScenes.clear();
        scanProcess.output = "";
        const script = 'src="$1"; cd "$src" 2>/dev/null || exit 0; for dir in */; do id="${dir%/}"; [[ -f "$id/project.json" ]] || continue; title=$(jq -r \'.title // empty\' "$id/project.json" 2>/dev/null); [[ -n "$title" ]] || title="$id"; printf "%s|%s\\n" "$id" "$title"; done';
        scanProcess.command = ["bash", "-c", script, "bash", source];
        scanProcess.running = true;
    }

    function filterScenes() {
        filteredScenes.clear();
        const term = searchText.toLowerCase();
        const playlist = Array.isArray(playlistSceneIds) ? playlistSceneIds : [];
        for (let i = 0; i < allScenes.count; ++i) {
            const scene = allScenes.get(i);
            if (playlistView && playlist.indexOf(scene.sceneId) < 0)
                continue;

            if (term && scene.sceneId.toLowerCase().indexOf(term) < 0 && String(scene.name || "").toLowerCase().indexOf(term) < 0)
                continue;

            filteredScenes.append({
                "sceneId": scene.sceneId,
                "name": scene.name
            });
        }
    }

    modalWidth: Math.min(screenWidth - 80, 1180)
    modalHeight: Math.min(screenHeight - 80, 780)
    layerNamespace: "dms:plugins:linuxWallpaperEngine"
    useOverlayLayer: false
    width: modalWidth
    height: modalHeight
    positioning: "center"
    allowStacking: true
    onPlaylistSceneIdsChanged: filterScenes()
    onNamedPlaylistsChanged: {
        rebuildPlaylistModel();
        const names = playlistNames();
        if (selectedPlaylistName && namedPlaylists[selectedPlaylistName] !== undefined) {
            playlistSceneIds = namedPlaylists[selectedPlaylistName].slice();
        } else if (names.length > 0) {
            selectedPlaylistName = names[0];
            playlistSceneIds = Array.isArray(namedPlaylists[names[0]]) ? namedPlaylists[names[0]].slice() : [];
        }
    }
    onNamedPlaylistSettingsChanged: loadSelectedPlaylistSettings()
    onDialogClosed: {
        saveCurrentScrollPosition();
        scrollPositionsSaved(scrollPositions);
        selectedSceneId = "";
        searchText = "";
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

    Process {
        id: scanProcess

        property string output: ""

        onExited: (code) => {
            if (code === 0 && output) {
                const lines = output.trim().split("\n");
                for (const line of lines) {
                    const split = line.indexOf("|");
                    if (split > 0)
                        allScenes.append({
                        "sceneId": line.slice(0, split),
                        "name": line.slice(split + 1)
                    });

                }
            }
            scanning = false;
            filterScenes();
            restoreScrollPosition(currentViewKey());
            output = "";
        }

        stdout: SplitParser {
            onRead: (data) => {
                return scanProcess.output += data + "\n";
            }
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
                }

                StyledText {
                    text: "Wallpaper Engine"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
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
            width: 224
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
                    active: !root.playlistView
                    onActivated: root.showLibrary()
                }

                StyledText {
                    width: parent.width
                    text: "PLAYLISTS"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.55
                }

                DankButton {
                    id: createPlaylistButton

                    width: parent.width
                    text: "+  New Playlist"
                    onClicked: root.createPlaylist()
                }

                Repeater {
                    model: playlistModel

                    delegate: NavItem {
                        required property string playlistName
                        required property int sceneCount

                        width: parent.width
                        iconName: playlistName === root.activePlaylistName ? "play_arrow" : "playlist_play"
                        label: playlistName
                        detail: sceneCount + ""
                        active: root.playlistView && root.selectedPlaylistName === playlistName
                        onActivated: root.selectPlaylist(playlistName)
                        onDoubleActivated: {
                            const list = root.namedPlaylists[playlistName];
                            if (Array.isArray(list) && list.length > 0) {
                                root.playlistActivated(playlistName);
                                root.close();
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
                    text: root.currentSceneId || "No active scene"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.8
                    wrapMode: Text.WrapAnywhere
                }

                StyledText {
                    width: parent.width
                    text: root.activePlaylistName ? "Active playlist: " + root.activePlaylistName : "Scene mode"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.65
                    elide: Text.ElideRight
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
                placeholderText: root.playlistView ? "Search " + root.selectedPlaylistName + "..." : "Search scenes..."
                text: root.searchText
                onTextChanged: {
                    root.searchText = text;
                    root.filterScenes();
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
                    const total = filteredScenes.count;
                    if (root.scanning)
                        return "Scanning scene library...";

                    if (!total)
                        return "No scenes";

                    const row = Math.max(0, Math.floor(sceneGrid.contentY / sceneGrid.cellHeight));
                    const first = Math.min(total, row * sceneGrid.columns + 1);
                    const rows = Math.ceil(sceneGrid.height / sceneGrid.cellHeight);
                    const last = Math.min(total, first + rows * sceneGrid.columns - 1);
                    return first + "-" + last + " of " + total;
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
                visible: root.playlistView && root.selectedPlaylistName !== ""
                spacing: Theme.spacingM

                StyledText {
                    text: "Switch every"
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankDropdown {
                    width: 130
                    options: ["1 min", "2 min", "5 min", "10 min", "15 min", "30 min", "60 min"]
                    currentValue: root.selectedIntervalMinutes + " min"
                    compactMode: true
                    transientSurfaceTracker: root.transientSurfaceTracker
                    onValueChanged: (value) => {
                        return root.updateSelectedPlaylistSettings(parseInt(value), root.selectedPlaylistShuffle);
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

                    property int columns: Math.max(3, Math.floor(width / 150))
                    property real wheelVelocity: 0

                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM + 14
                    clip: true
                    model: filteredScenes
                    boundsBehavior: Flickable.StopAtBounds
                    flickDeceleration: 3500
                    maximumFlickVelocity: 9000
                    keyNavigationEnabled: true
                    cacheBuffer: cellHeight * 2
                    cellWidth: width / columns
                    cellHeight: cellWidth + 54

                    Timer {
                        id: inertiaTimer

                        interval: 16
                        repeat: true
                        onTriggered: {
                            const maxY = Math.max(0, sceneGrid.contentHeight - sceneGrid.height);
                            const nextY = Math.max(0, Math.min(maxY, sceneGrid.contentY + sceneGrid.wheelVelocity));
                            sceneGrid.contentY = nextY;
                            sceneGrid.wheelVelocity *= 0.88;
                            if (Math.abs(sceneGrid.wheelVelocity) < 0.35 || (nextY === 0 && sceneGrid.wheelVelocity < 0) || (nextY === maxY && sceneGrid.wheelVelocity > 0)) {
                                sceneGrid.wheelVelocity = 0;
                                stop();
                            }
                        }
                    }

                    WheelHandler {
                        target: null
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            if (sceneGrid.contentHeight <= sceneGrid.height)
                                return ;

                            const pixel = event.pixelDelta.y;
                            const impulse = pixel !== 0 ? -pixel * 0.45 : -(event.angleDelta.y / 120) * 42;
                            sceneGrid.wheelVelocity = Math.max(-90, Math.min(90, sceneGrid.wheelVelocity + impulse));
                            inertiaTimer.start();
                            event.accepted = true;
                        }
                    }

                    delegate: Item {
                        id: delegateRoot

                        required property var modelData
                        property var scene: modelData || ({
                        })

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
                                    root.selectedSceneId = delegateRoot.scene.sceneId || "";
                                    root.applySelected();
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
                            const maxY = Math.max(0, sceneGrid.contentHeight - sceneGrid.height);
                            const travel = Math.max(1, height - scrollThumb.height);
                            sceneGrid.contentY = maxY * Math.max(0, Math.min(1, (yPos - scrollThumb.height / 2) / travel));
                        }

                        anchors.fill: parent
                        hoverEnabled: true
                        onPressed: (mouse) => {
                            return seek(mouse.y);
                        }
                        onPositionChanged: (mouse) => {
                            if (pressed)
                                seek(mouse.y);

                        }
                    }

                }

                StyledText {
                    anchors.centerIn: parent
                    visible: !root.scanning && filteredScenes.count === 0
                    text: root.playlistView ? "Playlist is empty" : "No scenes found"
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
                        visible: root.playlistView
                        enabled: root.selectedPlaylistName !== "Default" && root.playlistNames().length > 1
                        onClicked: root.playlistDeleted(root.selectedPlaylistName)
                    }

                    DankButton {
                        text: "Use Playlist"
                        visible: root.playlistView
                        enabled: root.playlistSceneIds.length > 0
                        onClicked: {
                            root.playlistActivated(root.selectedPlaylistName);
                            root.close();
                        }
                    }

                    DankDropdown {
                        width: 170
                        visible: !root.playlistView
                        options: root.playlistNames()
                        currentValue: root.selectedPlaylistName
                        compactMode: true
                        openUpwards: true
                        transientSurfaceTracker: root.transientSurfaceTracker
                        onValueChanged: (value) => {
                            return root.setAddTarget(value);
                        }
                    }

                    DankButton {
                        id: playlistButton

                        text: root.playlistView ? "Remove" : "Add"
                        enabled: root.selectedSceneId !== "" && root.selectedPlaylistName !== "" && (root.playlistView || !root.sceneInPlaylist(root.selectedSceneId))
                        onClicked: {
                            if (root.playlistView)
                                root.sceneRemovedFromPlaylist(root.selectedSceneId, root.selectedPlaylistName);
                            else
                                root.sceneAddedToPlaylist(root.selectedSceneId, root.selectedPlaylistName);
                        }
                    }

                    DankButton {
                        id: applyButton

                        text: "Apply"
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

        signal activated()
        signal doubleActivated()

        height: 44
        radius: Theme.cornerRadius
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
