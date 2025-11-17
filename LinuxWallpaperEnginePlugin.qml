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

    onPluginDataChanged: {
        syncScenesWithData()
    }

    function escapeRegex(str) {
        return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    }


    function deepEqual(a, b) {
        if (a === b) return true
        if (a === null || b === null) return false
        if (typeof a !== "object" || typeof b !== "object") return false

        const aIsArray = Array.isArray(a)
        const bIsArray = Array.isArray(b)
        if (aIsArray !== bIsArray) return false

        const aKeys = Object.keys(a)
        const bKeys = Object.keys(b)
        if (aKeys.length !== bKeys.length) return false

        for (let i = 0; i < aKeys.length; ++i) {
            const key = aKeys[i]
            if (!b.hasOwnProperty(key)) return false
            if (!deepEqual(a[key], b[key])) return false
        }

        return true
    }

    function syncScenesWithData() {
        const newScenes = pluginData.monitorScenes || {}

        for (const monitor in monitorScenes) {
            if (!newScenes.hasOwnProperty(monitor)) {
                // monitor removed
                stopWallpaperEngine(monitor, false, "")
            }
        }

        for (const monitor in newScenes) {
            const newSceneId = newScenes[monitor]
            const oldSceneId = monitorScenes[monitor]

            if (!newSceneId) {
                if (processes[monitor]) {
                    stopWallpaperEngine(monitor, false, "")
                }
                continue
            }

            const newSettings = getSceneSettings(newSceneId)

            let oldSettings = null
            if (processes[monitor] && processes[monitor].sceneId === oldSceneId) {
                oldSettings = processes[monitor].settings
            }

            const sceneChanged = newSceneId !== oldSceneId
            const settingsChanged = !deepEqual(newSettings || {}, oldSettings || {})

            if (sceneChanged || settingsChanged) {
                launchWallpaperEngine(monitor, newSceneId)
            }
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
                } else {
                    var volume = settings.volume
                    if (volume === undefined || volume === null) {
                        volume = 50
                    }

                    args.push("--volume")
                    args.push(String(volume))
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
                "pkill", "-f", ".*linux-wallpaperengine.*screen-root " + escapeRegex(monitor)
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
                if (!SessionData.perMonitorWallpaper) {
                    SessionData.setPerMonitorWallpaper(enabled)
                }
                SessionData.setMonitorWallpaper(monitor, screenshotPath)
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
            // synchronous process call blocking
            Quickshell.execDetached([
                "pkill", "-f", "linux-wallpaperengine.*--screen-root " + escapeRegex(monitor)
            ])
        }
    }
}
