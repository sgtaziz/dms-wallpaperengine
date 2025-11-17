import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
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

    signal sceneSelected(string sceneId)

    width: Math.min(screenWidth - 100, 1200)
    height: Math.min(screenHeight - 100, 800)
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
                    text: "Select Workshop Scene"
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

                        // choose how many columns you want; this keeps math explicit
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

                            // when this delegate is reused for a different scene
                            onSceneDataChanged: {
                                previewImg.extIndex = 0
                                previewImg.updateSource()
                            }

                            // the card, centered inside the cell
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

                                    Rectangle {
                                        id: previewFrame
                                        width: parent.width
                                        height: width            // square preview
                                        radius: Theme.cornerRadius
                                        color: "transparent"

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: previewFrame.radius
                                            color: Theme.surface
                                        }

                                        Rectangle {
                                            id: wallpaperMask
                                            anchors.fill: parent
                                            anchors.margins: 1
                                            radius: Theme.cornerRadius - 1
                                            color: "black"
                                            visible: false
                                            layer.enabled: true
                                        }

                                        AnimatedImage {
                                            id: previewImg
                                            anchors.fill: parent
                                            playing: true
                                            fillMode: Image.PreserveAspectCrop
                                            cache: true
                                            asynchronous: true

                                            property var extensions: [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"]
                                            property int extIndex: 0

                                            function sceneId() {
                                                return sceneDelegate.sceneData.sceneId || ""
                                            }

                                            function updateSource() {
                                                const sid = sceneId()
                                                if (!sid || extIndex < 0 || extIndex >= extensions.length) {
                                                    source = ""
                                                    return
                                                }
                                                source = "file://" + steamWorkshopPath + "/" + sid + "/preview" + extensions[extIndex]
                                            }

                                            Component.onCompleted: updateSource()

                                            onStatusChanged: {
                                                if (status === Image.Error) {
                                                    if (extIndex < extensions.length - 1) {
                                                        extIndex += 1
                                                        updateSource()
                                                    }
                                                } else if (status === Image.Ready) {
                                                    const url = source.toLowerCase()
                                                    const isGif = url.endsWith(".gif")
                                                    if (isGif) {
                                                        playing = false
                                                        currentFrame = 0
                                                        playing = true
                                                    } else {
                                                        playing = false
                                                    }
                                                }
                                            }

                                            StyledText {
                                                anchors.centerIn: parent
                                                text: "No Preview"
                                                opacity: 0.5
                                                visible: previewImg.status !== Image.Ready
                                            }

                                            layer.enabled: true
                                            layer.effect: MultiEffect {
                                                maskEnabled: true
                                                maskSource: wallpaperMask
                                            }
                                        }
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
            console.warn("No Steam Workshop path set")
            return
        }

        allScenes.clear()
        filteredScenes.clear()

        // Use bash script with jq to map sceneId => name
        // Falls back to just listing scene IDs if jq is not installed
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
                            const sceneName = parts.slice(1).join('|') // Handle names with | in them
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

    function readProjectJson(sceneId) {
        // This function is no longer needed as names are fetched during scan
        return sceneId
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
