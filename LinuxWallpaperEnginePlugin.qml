import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root

    property var monitorScenes: pluginData.monitorScenes || {}
    property var processes: ({})
    property string mainMonitor: {
        const monitors = Object.keys(monitorScenes)
        return monitors.length > 0 ? monitors[0] : ""
    }

    Connections {
        target: PluginService
        function onGlobalVarChanged(pluginId, varName) {
            if (pluginId === "linuxWallpaperEngine" && varName === "lastChange") {
                if (PluginService.getGlobalVar("linuxWallpaperEngine", "lastChange", 0) > 0) {
                    syncScenesWithData()
                }
            }
        }
    }

    onPluginDataChanged: {
        syncScenesWithData()
    }

    function syncScenesWithData() {
        const newScenes = pluginData.monitorScenes || {}

        for (const monitor in newScenes) {
            const sceneId = newScenes[monitor]
            const currentSceneId = monitorScenes[monitor]
            launchWallpaperEngine(monitor, sceneId)
        }

        monitorScenes = newScenes
    }

    function launchWallpaperEngine(monitor, sceneId) {
        stopWallpaperEngine(monitor, true, sceneId)
    }

    function getSceneSettings(sceneId) {
        var allSettings = pluginData.sceneSettings || {}
        return allSettings[sceneId] || {}
    }

    function stopWallpaperEngine(monitor, startNew, newSceneId) {
        if (startNew === undefined) startNew = false
        if (newSceneId === undefined) newSceneId = ""

        if (processes[monitor]) {
            processes[monitor].running = false
            processes[monitor].destroy()
            delete processes[monitor]
        }

        var killerProc = killerComponent.createObject(root, {
            monitor: monitor,
            startNew: startNew,
            newSceneId: newSceneId
        })
        killerProc.running = true
    }

    Component {
        id: weProcessComponent

        Process {
            id: weProc

            property string monitor: ""
            property string sceneId: ""
            property string screenshotPath: ""
            property var settings: ({})

            command: {
                var args = [
                    "linux-wallpaperengine",
                    "--screen-root", monitor,
                    "--screenshot", screenshotPath,
                    "--bg", sceneId
                ]

                if (settings.silent !== false) {
                    args.push("--silent")
                }

                var fps = settings.fps || 30
                if (fps !== 30) {
                    args.push("--fps")
                    args.push(String(fps))
                }

                var scaling = settings.scaling || "default"
                if (scaling !== "default") {
                    args.push("--scaling")
                    args.push(scaling)
                }

                var sceneProps = settings.properties || {}
                for (var propName in sceneProps) {
                    args.push("--set-property")
                    args.push(propName + "=" + sceneProps[propName])
                }

                return args
            }

            onExited: (code) => {
                if (code !== 0) {
                    console.warn("LinuxWallpaperEngine: Process exited with code:", code, "for scene", sceneId, "on", monitor)
                }
            }
        }
    }

    Component {
        id: killerComponent

        Process {
            property string monitor: ""
            property bool startNew: false
            property string newSceneId: ""

            command: [
                "pkill", "-f",
                "linux-wallpaperengine --screen-root " + monitor
            ]

            onExited: () => {
                if (startNew) {
                    const cacheHome = StandardPaths.writableLocation(StandardPaths.GenericCacheLocation).toString()
                    const baseDir = Paths.strip(cacheHome)
                    const outDir = baseDir + "/DankMaterialShell/we_screenshots"
                    const screenshotPath = outDir + "/" + newSceneId + ".jpg"

                    Quickshell.execDetached(["mkdir", "-p", outDir])

                    var sceneSettings = getSceneSettings(newSceneId)
                    var weProc = weProcessComponent.createObject(root, {
                        monitor: monitor,
                        sceneId: newSceneId,
                        screenshotPath: screenshotPath,
                        settings: sceneSettings
                    })

                    processes[monitor] = weProc
                    weProc.running = true

                    var setWallpaper = setWallpaperTimer.createObject(root, {
                        monitor: monitor,
                        screenshotPath: screenshotPath,
                        mainMonitor: root.mainMonitor
                    })
                    setWallpaper.running = true
                }

                destroy()
            }
        }
    }

    Component {
        id: setWallpaperTimer

        Timer {
            property string monitor: ""
            property string screenshotPath: ""
            property string mainMonitor: ""

            running: false
            repeat: false
            interval: 1500

            onTriggered: {
                console.info("Set wp on", monitor, "to", screenshotPath)
                SessionData.setMonitorWallpaper(monitor, screenshotPath)

                if (monitor === mainMonitor) {
                    console.info("Setting main wallpaper to", screenshotPath)
                    SessionData.setWallpaper(screenshotPath)
                }
            }
        }
    }

    Component.onCompleted: {
        console.info("LinuxWallpaperEngine: Plugin started")
        syncScenesWithData()
    }

    Component.onDestruction: {
        console.info("LinuxWallpaperEngine: Plugin stopping, cleaning up processes")

        for (const monitor in processes) {
            if (processes[monitor]) {
                processes[monitor].running = false
                processes[monitor].destroy()
            }
        }

        for (const monitor in monitorScenes) {
            var killerProc = killerComponent.createObject(root, {
                monitor: monitor
            })
            killerProc.running = true
        }
    }
}
