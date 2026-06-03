import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
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
    property bool pauseOnPowerSaver: pluginData.pauseOnPowerSaver || false
    property bool pauseOnBattery: pluginData.pauseOnBattery || false

    readonly property bool shouldPauseWallpaper: {
        if (pauseOnPowerSaver && typeof PowerProfiles !== "undefined" && PowerProfiles.profile === PowerProfile.PowerSaver) return true
        if (pauseOnBattery && BatteryService.batteryAvailable && !BatteryService.isPluggedIn) return true
        return false
    }

    onShouldPauseWallpaperChanged: {
        if (!ready) return
        if (shouldPauseWallpaper) {
            console.info("LinuxWallpaperEngine: Pausing wallpapers (power state change)")
            for (const monitor of Quickshell.screens.map(s => s.name)) {
                if (processes[monitor]) stopWallpaperEngine(monitor, false, "")
            }
        } else {
            console.info("LinuxWallpaperEngine: Resuming wallpapers (power state change)")
            syncScenesWithData()
        }
    }
    property string mainMonitor: {
        const monitors = Object.keys(monitorScenes)
        return monitors.length > 0 ? monitors[0] : ""
    }
    property var previousScreenNames: []
    property var playlistIndices: ({})
    property bool ready: false
    property var pendingLaunches: ({})

    onPluginDataChanged: {
        if (ready) {
            syncDebounce.restart()
        }
    }

    Timer {
        id: syncDebounce
        interval: 50
        repeat: false
        onTriggered: syncScenesWithData()
    }

    // Watch for display hotplug events (connect/disconnect)
    Connections {
        target: Quickshell

        function onScreensChanged() {
            const currentScreenNames = Quickshell.screens.map(screen => screen.name)

            // Find disconnected screens and stop their processes
            const removedScreens = previousScreenNames.filter(name => !currentScreenNames.includes(name))
            for (const screenName of removedScreens) {
                if (processes[screenName]) {
                    console.info("LinuxWallpaperEngine: Display disconnected:", screenName, "- stopping scene")
                    stopWallpaperEngine(screenName, false, "")
                }
            }

            // Find newly connected screens and restore their scenes
            const newScreens = currentScreenNames.filter(name => !previousScreenNames.includes(name))
            for (const screenName of newScreens) {
                const sceneId = getEffectiveScene(screenName)
                if (sceneId) {
                    console.info("LinuxWallpaperEngine: Display connected:", screenName, "- restoring scene:", sceneId)
                    launchWallpaperEngine(screenName, sceneId)
                }
            }

            previousScreenNames = currentScreenNames
        }
    }

    onGenerateStaticWallpaperChanged: {
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
        if (hasAny) {
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
        const connectedMonitors = ["*", ...Quickshell.screens.map(screen => screen.name)]
        console.info("LinuxWallpaperEngine: Syncing scenes. Connected monitors:", JSON.stringify(connectedMonitors))
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
            const isPending = monitor == "*" ? false : pendingLaunches[monitor]

            console.info("LinuxWallpaperEngine: Monitor", monitor, "- sceneChanged:", sceneChanged, "settingsChanged:", settingsChanged, "processNotRunning:", processNotRunning, "isPending:", isPending)

            if ((sceneChanged || settingsChanged || processNotRunning) && !isPending && !shouldPauseWallpaper) {
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
        pendingLaunches[monitor] = true
        stopWallpaperEngine(monitor, true, sceneId)
    }

    function getSceneSettings(sceneId) {
        var allSettings = pluginData.sceneSettings || {}
        return allSettings[sceneId] || {}
    }

    function stopWallpaperEngine(virtualMonitor, startNew, newSceneId) {
        if (startNew === undefined) startNew = false
        if (newSceneId === undefined) newSceneId = ""

        var monitors = [virtualMonitor];
        if (virtualMonitor == "*") {
            monitors = Quickshell.screens.map(screen => screen.name);
        }

        var isFirstMonitor = true;
        for (const monitor of monitors) {
            if (processes[monitor]) {
                processes[monitor].running = false
                processes[monitor].destroy()
                delete processes[monitor]
            }

            var killerProc = killerComponent.createObject(root, {
                monitor: monitor,
                startNew: startNew,
                newSceneId: newSceneId,
                forceNoAudio: !isFirstMonitor
            })
            killerProc.running = true

            isFirstMonitor = false;
        }
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
            property bool forceNoAudio: false

            command: {
                var args = [
                    "linux-wallpaperengine",
                    "--screen-root", monitor
                ]

                if (useScreenshot && screenshotPath) {
                    args.push("--screenshot")
                    args.push(screenshotPath)
                    var screenshotDelay = settings.screenshotDelay || 5
                    if (screenshotDelay !== 5) {
                        args.push("--screenshot-delay")
                        args.push(String(screenshotDelay))
                    }
                }

                args.push("--bg")
                args.push(sceneId)

                if (forceNoAudio || settings.silent !== false) {
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
            property bool forceNoAudio: false

            command: [
                "pkill", "-f", ".*linux-wallpaperengine.*--screen-root " + escapeRegex(monitor)
            ]


            onExited: () => {
                if (!startNew) {
                    delete pendingLaunches[monitor]
                }
                if (startNew) {
                    if (!root.ready || root.shouldPauseWallpaper) {
                        delete pendingLaunches[monitor]
                        destroy()
                        return
                    }

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
                        settings: sceneSettings,
                        forceNoAudio: forceNoAudio
                    })

                    processes[monitor] = weProc
                    weProc.running = true
                    delete pendingLaunches[monitor]

                    if (useScreenshot) {
                        var screenshotDelay = sceneSettings.screenshotDelay || 5
                        var fps = sceneSettings.fps || 30
                        var calculatedDelay = Math.round((screenshotDelay / fps) * 1000)
                        var setWallpaper = setWallpaperTimer.createObject(root, {
                            monitor: monitor,
                            screenshotPath: screenshotPath,
                            mainMonitor: root.mainMonitor,
                            delayMs: 1500 + calculatedDelay
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
            property int delayMs: 1500

            running: false
            repeat: false
            interval: delayMs

            onTriggered: {
                console.info("LinuxWallpaperEngine: Set wp on", monitor, "to", screenshotPath)
                if (!SessionData.perMonitorWallpaper) {
                    SessionData.setPerMonitorWallpaper(true)
                }
                SessionData.setMonitorWallpaper(monitor, screenshotPath)
            }
        }
    }

    Timer {
        id: playlistTimer
        running: false
        repeat: true
        interval: playlistIntervalMinutes * 60 * 1000
        onTriggered: {
            for (const monitor in monitorPlaylists) {
                if (hasActivePlaylist(monitor)) {
                    advancePlaylist(monitor)
                }
            }
        }
    }

    function toggle() {
        if (ready) {
            for (const monitor in processes) {
                stopWallpaperEngine(monitor, false, "")
            }
            ready = false
            playlistTimer.running = false
            console.info("LinuxWallpaperEngine: Toggled OFF")
        } else {
            previousScreenNames = Quickshell.screens.map(screen => screen.name)
            prevGenerateStaticWallpaper = generateStaticWallpaper
            ready = true
            syncScenesWithData()
            console.info("LinuxWallpaperEngine: Toggled ON")
        }
    }

    Component.onCompleted: {
        previousScreenNames = Quickshell.screens.map(screen => screen.name)
        console.info("LinuxWallpaperEngine: Plugin starting...")
        prevGenerateStaticWallpaper = generateStaticWallpaper
        ready = true
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
            Quickshell.execDetached([
                "pkill", "-f", ".*linux-wallpaperengine.*--screen-root " + escapeRegex(monitor)
            ])
        }
    }
}
