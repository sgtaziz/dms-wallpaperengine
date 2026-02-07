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
    property var monitorPlaylists: pluginData.monitorPlaylists || {}
    property bool playlistShuffle: pluginData.playlistShuffle || false
    property int playlistIntervalMinutes: Math.max(1, pluginData.playlistIntervalMinutes || 5)
    property var processes: ({})
    property bool generateStaticWallpaper: pluginData.generateStaticWallpaper || false
    property bool prevGenerateStaticWallpaper: false
    property bool isActiveInstance: false
    property string mainMonitor: {
        const monitors = Object.keys(monitorScenes)
        return monitors.length > 0 ? monitors[0] : ""
    }
    property var previousScreenNames: []
    property var playlistIndices: ({})

    onPluginDataChanged: {
        if (isActiveInstance) {
            syncScenesWithData()
        }
    }

    // Watch for display hotplug events (connect/disconnect)
    Connections {
        target: Quickshell

        function onScreensChanged() {
            if (!isActiveInstance) return
            const currentScreenNames = Quickshell.screens.map(screen => screen.name)

            // Find disconnected screens and stop their processes
            const removedScreens = previousScreenNames.filter(name => !currentScreenNames.includes(name))
            for (const screenName of removedScreens) {
                if (processes[screenName]) {
                    stopWallpaperEngine(screenName, false, "")
                }
            }

            // Find newly connected screens and restore their scenes
            const newScreens = currentScreenNames.filter(name => !previousScreenNames.includes(name))
            for (const screenName of newScreens) {
                const sceneId = getEffectiveScene(screenName)
                if (sceneId) {
                    launchWallpaperEngine(screenName, sceneId)
                }
            }

            previousScreenNames = currentScreenNames
        }
    }

    onGenerateStaticWallpaperChanged: {
        if (!isActiveInstance) return
        if (prevGenerateStaticWallpaper !== generateStaticWallpaper) {
            prevGenerateStaticWallpaper = generateStaticWallpaper
            for (const monitor in monitorScenes) {
                const sceneId = monitorScenes[monitor]
                if (sceneId) {
                    launchWallpaperEngine(monitor, sceneId)
                }
            }
        }
    }

    function hasActivePlaylist(monitor) {
        const p = monitorPlaylists[monitor]
        return p && Array.isArray(p) && p.length > 1
    }

    function restartPlaylistTimers() {
        playlistTimer.interval = playlistIntervalMinutes * 60 * 1000
        const hasAny = Object.keys(monitorPlaylists || {}).some(m => hasActivePlaylist(m))
        if (hasAny && isActiveInstance) {
            playlistTimer.restart()
            playlistTimer.running = true
        } else {
            playlistTimer.running = false
        }
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

    function getEffectiveScene(monitor) {
        const playlist = monitorPlaylists[monitor]
        if (playlist && Array.isArray(playlist) && playlist.length > 0) {
            let idx = playlistIndices[monitor]
            if (idx === undefined || idx < 0 || idx >= playlist.length) {
                idx = playlistShuffle ? Math.floor(Math.random() * playlist.length) : 0
                const indices = Object.assign({}, playlistIndices)
                indices[monitor] = idx
                playlistIndices = indices
            }
            return playlist[idx]
        }
        return (pluginData.monitorScenes || {})[monitor] || ""
    }

    function advancePlaylist(monitor) {
        const playlist = monitorPlaylists[monitor]
        if (!playlist || !Array.isArray(playlist) || playlist.length === 0) return
        let nextSceneId
        let nextIdx
        if (playlistShuffle) {
            const currentIdx = playlistIndices[monitor]
            if (playlist.length === 1) {
                nextIdx = 0
            } else {
                let candidate
                do {
                    candidate = Math.floor(Math.random() * playlist.length)
                } while (candidate === currentIdx)
                nextIdx = candidate
            }
            nextSceneId = playlist[nextIdx]
        } else {
            const idx = (playlistIndices[monitor] || 0) + 1
            nextIdx = idx >= playlist.length ? 0 : idx
            nextSceneId = playlist[nextIdx]
        }
        const indices = Object.assign({}, playlistIndices)
        indices[monitor] = nextIdx
        playlistIndices = indices
        const newScenes = Object.assign({}, pluginData.monitorScenes || {})
        newScenes[monitor] = nextSceneId
        pluginData.monitorScenes = newScenes
        if (pluginService && pluginService.savePluginData) {
            pluginService.savePluginData(pluginId, "monitorScenes", newScenes)
        }
        launchWallpaperEngine(monitor, nextSceneId)
    }

    function syncScenesWithData() {
        const connectedMonitors = Quickshell.screens.map(screen => screen.name)
        const effectiveScenes = {}
        for (const monitor of connectedMonitors) {
            const scene = getEffectiveScene(monitor)
            if (scene) effectiveScenes[monitor] = scene
        }

        for (const monitor in monitorScenes) {
            if (!effectiveScenes.hasOwnProperty(monitor) && !(monitorPlaylists[monitor] && monitorPlaylists[monitor].length > 0)) {
                stopWallpaperEngine(monitor, false, "")
            }
        }

        const newScenes = Object.assign({}, pluginData.monitorScenes || {})
        for (const monitor of connectedMonitors) {
            const newSceneId = effectiveScenes[monitor]
            const oldSceneId = processes[monitor] ? processes[monitor].sceneId : ""

            if (!newSceneId) {
                if (processes[monitor]) {
                    stopWallpaperEngine(monitor, false, "")
                }
                continue
            }

            newScenes[monitor] = newSceneId
            const newSettings = getSceneSettings(newSceneId)

            let oldSettings = null
            if (processes[monitor] && processes[monitor].sceneId === oldSceneId) {
                oldSettings = processes[monitor].settings
            }

            const sceneChanged = newSceneId !== oldSceneId
            const settingsChanged = !deepEqual(newSettings || {}, oldSettings || {})
            const processNotRunning = !processes[monitor]

            if (sceneChanged || settingsChanged || processNotRunning) {
                launchWallpaperEngine(monitor, newSceneId)
            }
        }

        if (!deepEqual(pluginData.monitorScenes || {}, newScenes)) {
            pluginData.monitorScenes = newScenes
            if (pluginService && pluginService.savePluginData) {
                pluginService.savePluginData(pluginId, "monitorScenes", newScenes)
            }
        }
        monitorScenes = newScenes
        restartPlaylistTimers()
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
            property bool useScreenshot: false
            property var settings: ({})

            command: {
                var args = [
                    "linux-wallpaperengine",
                    "--screen-root", monitor
                ]

                if (useScreenshot && screenshotPath) {
                    args.push("--screenshot")
                    args.push(screenshotPath)
                }

                args.push("--bg")
                args.push(sceneId)

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

                if (settings.disableParticles) args.push("--disable-particles")
                if (settings.disableMouse) args.push("--disable-mouse")
                if (settings.disableParallax) args.push("--disable-parallax")
                if (settings.noAutoMute) args.push("--noautomute")
                if (settings.noAudioProcessing) args.push("--no-audio-processing")
                if (settings.noFullscreenPause) args.push("--no-fullscreen-pause")
                if (settings.fullscreenPauseOnlyActive) args.push("--fullscreen-pause-only-active")

                return args
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
                "pkill", "-f", ".*linux-wallpaperengine.*--screen-root " + escapeRegex(monitor)
            ]


            onExited: () => {
                if (startNew) {
                    const useScreenshot = root.generateStaticWallpaper
                    var screenshotPath = ""

                    if (useScreenshot) {
                        const cacheHome = StandardPaths.writableLocation(StandardPaths.GenericCacheLocation).toString()
                        const baseDir = Paths.strip(cacheHome)
                        const outDir = baseDir + "/DankMaterialShell/we_screenshots"
                        screenshotPath = outDir + "/" + newSceneId + ".jpg"

                        Quickshell.execDetached(["mkdir", "-p", outDir])
                    }

                    var sceneSettings = getSceneSettings(newSceneId)
                    var weProc = weProcessComponent.createObject(root, {
                        monitor: monitor,
                        sceneId: newSceneId,
                        screenshotPath: screenshotPath,
                        useScreenshot: useScreenshot,
                        settings: sceneSettings
                    })

                    processes[monitor] = weProc
                    weProc.running = true

                    if (useScreenshot) {
                        var setWallpaper = setWallpaperTimer.createObject(root, {
                            monitor: monitor,
                            screenshotPath: screenshotPath,
                            mainMonitor: root.mainMonitor
                        })
                        setWallpaper.running = true
                    }
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
                if (!SessionData.perMonitorWallpaper) {
                    SessionData.setPerMonitorWallpaper(true)
                }
                SessionData.setMonitorWallpaper(monitor, screenshotPath)
            }
        }
    }

    Process {
        id: startupCleanup
        command: ["bash", "-c", "pkill -f linux-wallpaperengine 2>/dev/null; fuser -k /tmp/lwe-instance.lock 2>/dev/null; sleep 0.2; true"]
        onExited: (code) => {
            lockChecker.running = true
            instanceCheckTimer.start()
        }
    }

    Process {
        id: lockChecker
        command: ["bash", "-c", "exec 200>/tmp/lwe-instance.lock; flock -n 200 || exit 1; sleep infinity"]

    }

    Timer {
        id: instanceCheckTimer
        interval: 100
        repeat: false
        onTriggered: {
            if (lockChecker.running) {
                isActiveInstance = true
                prevGenerateStaticWallpaper = generateStaticWallpaper
                syncScenesWithData()
            }
        }
    }

    Timer {
        id: playlistTimer
        running: false
        repeat: true
        interval: playlistIntervalMinutes * 60 * 1000
        onTriggered: {
            if (!isActiveInstance) return
            for (const monitor in monitorPlaylists) {
                if (hasActivePlaylist(monitor)) {
                    advancePlaylist(monitor)
                }
            }
        }
    }

    Component.onCompleted: {
        previousScreenNames = Quickshell.screens.map(screen => screen.name)
        startupCleanup.running = true
    }

    Component.onDestruction: {
        if (lockChecker.running) {
            lockChecker.running = false
        }

        for (const monitor in processes) {
            if (processes[monitor]) {
                processes[monitor].running = false
                processes[monitor].destroy()
            }
        }

        for (const monitor in monitorScenes) {
            Quickshell.execDetached([
                "pkill", "-f", ".*linux-wallpaperengine.*--screen-root " + escapeRegex(monitor)
            ])
        }
    }
}
