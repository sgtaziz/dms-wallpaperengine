import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    property var getOutputSetting
    property var saveOutputSetting
    property string settingsSceneId: ""

    signal configurePropertiesRequested()

    width: parent.width
    spacing: Theme.spacingM

    StyledText {
        text: "Wallpaper Settings"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    Column {
        width: parent.width
        spacing: 2

        Row {
            id: scalingRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Scaling"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }

            DankDropdown {
                id: scalingDropdown
                width: parent.width - 180 - Theme.spacingM
                options: ["default", "stretch", "fit", "fill"]
                compactMode: true

                Binding {
                    target: scalingDropdown
                    property: "currentValue"
                    value: getOutputSetting("scaling", "default")
                }

                onValueChanged: (value) => {
                    saveOutputSetting("scaling", value)
                }
            }
        }
        StyledText {
            text: "How the wallpaper is scaled to fit the screen"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Timer {
        id: fpsDebounceTimer
        interval: 500
        repeat: false
        onTriggered: {
            saveOutputSetting("fps", Math.round(fpsSlider.value))
        }
    }

    Column {
        width: parent.width
        spacing: 2

        Row {
            id: fpsRow
            width: parent.width
            height: 24
            spacing: Theme.spacingM

            StyledText {
                text: "FPS"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }

            DankSlider {
                id: fpsSlider
                width: parent.width - 180 - Theme.spacingM - fpsValueText.width - Theme.spacingM
                minimum: 10
                maximum: 144
                showValue: false
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: fpsSlider
                    property: "value"
                    value: getOutputSetting("fps", 30)
                }

                onSliderValueChanged: (newValue) => {
                    fpsDebounceTimer.restart()
                }
            }

            StyledText {
                id: fpsValueText
                text: Math.round(fpsSlider.value)
                font.pixelSize: Theme.fontSizeSmall
                width: 40
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        StyledText {
            text: "Frame rate for the animated wallpaper"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Column {
        width: parent.width
        spacing: 2

        Row {
            id: silentRow
            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                text: "Silent Mode"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }

            DankToggle {
                id: silentToggle
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: silentToggle
                    property: "checked"
                    value: getOutputSetting("silent", true)
                }

                onToggled: {
                    saveOutputSetting("silent", checked)
                }
            }
        }
        StyledText {
            text: "Mute all wallpaper audio"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Timer {
        id: volumeDebounceTimer
        interval: 500
        repeat: false
        onTriggered: {
            saveOutputSetting("volume", Math.round(volumeSlider.value))
        }
    }

    Column {
        width: parent.width
        spacing: 2
        visible: !getOutputSetting("silent", true)

        Row {
            id: volumeRow
            width: parent.width
            height: 24
            spacing: Theme.spacingM

            StyledText {
                text: "Volume"
                font.pixelSize: Theme.fontSizeSmall
                width: 180
                anchors.verticalCenter: parent.verticalCenter
            }

            DankSlider {
                id: volumeSlider
                width: parent.width - 180 - Theme.spacingM - volumeValueText.width - Theme.spacingM
                minimum: 0
                maximum: 100
                showValue: false
                anchors.verticalCenter: parent.verticalCenter

                Binding {
                    target: volumeSlider
                    property: "value"
                    value: getOutputSetting("volume", 50)
                }

                onSliderValueChanged: (newValue) => {
                    volumeDebounceTimer.restart()
                }
            }

            StyledText {
                id: volumeValueText
                text: Math.round(volumeSlider.value)
                font.pixelSize: Theme.fontSizeSmall
                width: 40
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        StyledText {
            text: "Audio volume when silent mode is off"
            font.pixelSize: Theme.fontSizeSmall * 0.9
            opacity: 0.5
            width: parent.width
            wrapMode: Text.Wrap
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineStrong
    }

    StyledText {
        text: "Advanced Settings"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Component {
            id: settingGroupComponent
            Column {
                property string title: ""
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    text: title
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    opacity: 0.8
                }
            }
        }

        Component {
            id: toggleItemComponent
            Column {
                property string label: ""
                property string description: ""
                property string settingKey: ""
                property bool defaultVal: false
                width: parent.width
                spacing: 2

                Row {
                    width: parent.width
                    spacing: Theme.spacingM
                    StyledText {
                        text: label
                        font.pixelSize: Theme.fontSizeSmall
                        width: 180
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    DankToggle {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: getOutputSetting(settingKey, defaultVal)
                        onToggled: (checked) => {
                            saveOutputSetting(settingKey, checked)
                        }
                    }
                }
                StyledText {
                    text: description
                    font.pixelSize: Theme.fontSizeSmall * 0.9
                    opacity: 0.5
                    width: parent.width
                    wrapMode: Text.Wrap
                }
            }
        }

        function createGroup(title, items) {
            var group = settingGroupComponent.createObject(this, { title: title })
            for (var i = 0; i < items.length; i++) {
                toggleItemComponent.createObject(group, items[i])
            }
        }

        Component.onCompleted: {
            createGroup("Performance & Rendering", [
                {
                    label: "Disable Particles",
                    description: "Disables particles for the backgrounds",
                    settingKey: "disableParticles"
                },
                {
                    label: "Disable Parallax",
                    description: "Disables parallax effect for the backgrounds",
                    settingKey: "disableParallax"
                },
                {
                    label: "No Fullscreen Pause",
                    description: "Prevents the background pausing when an app is fullscreen",
                    settingKey: "noFullscreenPause"
                },
                {
                    label: "Pause Only Active",
                    description: "Wayland only: pause only when a fullscreen window is active (activated)",
                    settingKey: "fullscreenPauseOnlyActive"
                }
            ])

            createGroup("Audio", [
                {
                    label: "No Auto Mute",
                    description: "Disables the automute when an app is playing sound",
                    settingKey: "noAutoMute"
                },
                {
                    label: "No Audio Processing",
                    description: "Disables audio processing for backgrounds",
                    settingKey: "noAudioProcessing"
                }
            ])

            createGroup("Interaction", [
                {
                    label: "Disable Mouse",
                    description: "Disables mouse interaction with the backgrounds",
                    settingKey: "disableMouse"
                }
            ])
        }
    }
}
