import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modals.Common

DankModal {
    id: root

    property string steamWorkshopPath: ""
    property var sceneList: []
    property string selectedSceneId: ""
    property string searchText: ""
    property bool addToPlaylistMode: false

    signal sceneSelected(string sceneId)

    modalWidth: Math.min(screenWidth - 100, 1200)
    modalHeight: Math.min(screenHeight - 100, 800)
    width: modalWidth
    height: modalHeight
    positioning: "center"
    allowStacking: true

    onDialogClosed: {
        selectedSceneId = ""
        searchText = ""
    }

    content: Item {
        anchors.fill: parent

        Rectangle {
            id: header
            width: parent.width
            height: 60
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
                    text: "Select Workshop Scene" + (addToPlaylistMode ? " to Add to Playlist" : "")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
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
            id: contentContainer
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            color: "transparent"

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    DankTextField {
                        id: searchField
                        width: parent.width - refreshButton.width - Theme.spacingM
                        placeholderText: "Search scenes..."
                        text: root.searchText
                        onTextChanged: {
                            root.searchText = text
                            filterScenes()
                        }
                    }

                    DankButton {
                        id: refreshButton
                        text: "Refresh"
                        onClicked: scanScenes()
                    }
                }

                StyledText {
                    id: sceneCountText
                    text: filteredScenes.count + " scenes found"
                    font.pixelSize: Theme.fontSizeSmall
                    opacity: 0.7
                }

                Rectangle {
                    width: parent.width
                    height: Math.max(220, parent.height - searchField.height - sceneCountText.height - Theme.spacingM * 2)
                    color: Theme.surface
                    radius: Theme.cornerRadius
                    border.width: 0
                    border.color: Theme.outlineStrong

                    GridView {
                        id: sceneGrid
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        clip: true
                        model: filteredScenes

                        property int columns: 6
                        cellWidth: width / columns
                        cellHeight: cellWidth + 2 * Theme.spacingS + 2 * Theme.fontSizeSmall + Theme.spacingS

                        ScrollBar.vertical: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }

                        delegate: Item {
                            id: sceneDelegate
                            required property var modelData
                            required property int index

                            width: sceneGrid.cellWidth
                            height: sceneGrid.cellHeight

                            property var sceneData: modelData || {}

                            Rectangle {
                                id: card
                                width: sceneGrid.cellWidth - Theme.spacingM
                                height: sceneGrid.cellHeight - Theme.spacingM
                                anchors.centerIn: parent

                                color: mouseArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                                radius: Theme.cornerRadius
                                border.width: selectedSceneId === sceneData.sceneId ? 2 : 1
                                border.color: selectedSceneId === sceneData.sceneId ? Theme.primary : Theme.outlineStrong

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS

                                    ScenePreview {
                                        width: parent.width
                                        height: width
                                        roundedMask: true
                                        animate: true
                                        fallbackText: "No Preview"
                                        sceneId: sceneDelegate.sceneData.sceneId || ""
                                        steamWorkshopPath: root.steamWorkshopPath
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: sceneDelegate.sceneData.name || sceneDelegate.sceneData.sceneId || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: "ID: " + (sceneDelegate.sceneData.sceneId || "")
                                        font.pixelSize: Theme.fontSizeSmall
                                        opacity: 0.7
                                        elide: Text.ElideRight
                                        wrapMode: Text.NoWrap
                                    }
                                }

                                MouseArea {
                                    id: mouseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        if (sceneDelegate.sceneData.sceneId) {
                                            selectedSceneId = sceneDelegate.sceneData.sceneId
                                            sceneSelected(selectedSceneId)
                                            root.close()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        anchors.centerIn: parent
                        text: root.searchText ? "No scenes match your search" : "No scenes found. Make sure Steam Workshop path is correct."
                        opacity: 0.7
                        visible: filteredScenes.count === 0
                        wrapMode: Text.Wrap
                        width: parent.width - 40
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }

    ListModel {
        id: allScenes
    }

    ListModel {
        id: filteredScenes
    }

    Component.onCompleted: {
        scanScenes()
    }

    function scanScenes() {
        if (!steamWorkshopPath) {
            return
        }

        allScenes.clear()
        filteredScenes.clear()

        sceneScanProcess.command = ["bash", "-c",
            `cd "${steamWorkshopPath}" && for dir in */; do
                id="\${dir%/}"
                if [[ "$id" =~ ^[0-9]+$ ]]; then
                    if command -v jq >/dev/null 2>&1 && [[ -f "$id/project.json" ]]; then
                        title=$(jq -r '.title // empty' "$id/project.json" 2>/dev/null)
                        if [[ -n "$title" ]]; then
                            echo "$id|$title"
                        else
                            echo "$id|$id"
                        fi
                    else
                        echo "$id|$id"
                    fi
                fi
            done`
        ]
        sceneScanProcess.running = true
    }

    Process {
        id: sceneScanProcess
        property string sceneOutput: ""

        stdout: SplitParser {
            onRead: (data) => {
                sceneScanProcess.sceneOutput += data+"\n"
            }
        }

        onExited: (code) => {
            if (code === 0 && sceneOutput) {
                const lines = sceneOutput.trim().split('\n')
                for (const line of lines) {
                    const trimmedLine = line.trim()
                    if (trimmedLine) {
                        const parts = trimmedLine.split('|')
                        if (parts.length >= 2) {
                            const sceneId = parts[0]
                            const sceneName = parts.slice(1).join('|')
                            allScenes.append({
                                sceneId: sceneId,
                                name: sceneName
                            })
                        }
                    }
                }
                filterScenes()
            }
            sceneOutput = ""
        }
    }

    function filterScenes() {
        filteredScenes.clear()
        const searchTerm = searchText.toLowerCase()

        for (let i = 0; i < allScenes.count; i++) {
            const scene = allScenes.get(i)
            if (!searchTerm ||
                scene.sceneId.includes(searchTerm) ||
                (scene.name && scene.name.toLowerCase().includes(searchTerm))) {
                filteredScenes.append(scene)
            }
        }
    }
}
