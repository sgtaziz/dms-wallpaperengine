import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "js/Utils.js" as Utils
import "js/CommandBuilder.js" as CommandBuilder

PluginComponent {
    id: root

    property var monitorScenes: pluginData.monitorScenes || {}
    property var monitorPlaylists: pluginData.monitorPlaylists || {}
    property var spanGroups: pluginData.spanGroups || []
    property var outputSettings: pluginData.outputSettings || {}
    property string activeType: pluginData.activeType || "scene"
    property bool playlistShuffle: pluginData.playlistShuffle || false
    property int playlistIntervalMinutes: Math.max(0, pluginData.playlistIntervalMinutes !== undefined ? pluginData.playlistIntervalMinutes : 5)
    property bool generateStaticWallpaper: pluginData.generateStaticWallpaper || false
    property bool prevGenerateStaticWallpaper: false
    property bool pauseOnPowerSaver: pluginData.pauseOnPowerSaver || false
    property bool pauseOnBattery: pluginData.pauseOnBattery || false

    property var processes: ({})
    property var launchSignatures: ({})
    property var playlistIndices: ({})
    property var pendingLaunches: ({})
    property var pendingKillers: ({})
    property bool ready: false
    property bool haveMagick: false
    property bool paused: false

    readonly property bool shouldPauseWallpaper: {
        if (pauseOnPowerSaver && typeof PowerProfiles !== "undefined" && PowerProfiles.profile === PowerProfile.PowerSaver) return true
        if (pauseOnBattery && BatteryService.batteryAvailable && !BatteryService.isPluggedIn) return true
        return false
    }

    onShouldPauseWallpaperChanged: {
        if (!ready) return
        if (shouldPauseWallpaper) {
            console.info("LinuxWallpaperEngine: Pausing wallpapers (power state change)")
            pauseOutputs()
        } else {
            console.info("LinuxWallpaperEngine: Resuming wallpapers (power state change)")
            resumeOutputs()
        }
    }

    onPluginDataChanged: {
        if (ready) syncDebounce.restart()
    }

    Timer {
        id: syncDebounce
        interval: 50
        repeat: false
        onTriggered: syncScenesWithData()
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (!ready) return
            syncDebounce.restart()
        }
    }

    onGenerateStaticWallpaperChanged: {
        if (prevGenerateStaticWallpaper !== generateStaticWallpaper && ready) {
            prevGenerateStaticWallpaper = generateStaticWallpaper
            stopAllOutputs()
            syncScenesWithData()
        }
    }

    function getSceneSettings(sceneId) {
        const allSettings = pluginData.sceneSettings || {}
        return allSettings[sceneId] || {}
    }

    function getOutputSettings(owner, sceneId) {
        const merged = Object.assign({}, outputSettings[owner] || {})
        merged.properties = (getSceneSettings(sceneId) || {}).properties || {}
        return merged
    }

    function connectedMonitors() {
        return Quickshell.screens.map(s => s.name)
    }

    function spanGroupById(id) {
        const groups = spanGroups || []
        for (let i = 0; i < groups.length; ++i) {
            if (groups[i].id === id) return groups[i]
        }
        return null
    }

    function ownerPlaylist(owner) {
        if (!owner) return null
        if (owner.indexOf("span:") === 0) {
            const g = spanGroupById(owner.slice(5))
            const p = g ? (g.playlist || []) : []
            return (Array.isArray(p) && p.length > 0) ? p : null
        }
        const p = monitorPlaylists[owner]
        return (Array.isArray(p) && p.length > 0) ? p : null
    }

    function ownerStaticScene(owner) {
        if (!owner) return ""
        if (owner.indexOf("span:") === 0) {
            const g = spanGroupById(owner.slice(5))
            return g ? (g.scene || "") : ""
        }
        return monitorScenes[owner] || ""
    }

    function hasConfig(owner) {
        if (!owner) return false
        if (activeType === "span") {
            return false
        }
        if (activeType === "scene") {
            return !!ownerStaticScene(owner)
        }
        return !!ownerPlaylist(owner)
    }

    function setPlaylistIndex(owner, idx) {
        const indices = Object.assign({}, playlistIndices)
        indices[owner] = idx
        playlistIndices = indices
    }

    function ownerCurrentScene(owner, persist) {
        const isSpan = owner && owner.indexOf("span:") === 0
        const usePlaylist = isSpan ? !!ownerPlaylist(owner) : (activeType === "playlist")
        if (usePlaylist) {
            const playlist = ownerPlaylist(owner)
            if (playlist) {
                let idx = playlistIndices[owner]
                if (idx === undefined || idx < 0 || idx >= playlist.length) {
                    idx = playlistShuffle ? Math.floor(Math.random() * playlist.length) : 0
                    if (persist !== false) setPlaylistIndex(owner, idx)
                }
                return playlist[idx]
            }
        }
        return ownerStaticScene(owner)
    }

    function resolveOwner(monitor) {
        if (hasConfig(monitor)) return monitor
        if (hasConfig("*")) return "*"
        return ""
    }

    function computeOutputs() {
        const connected = connectedMonitors()
        const connSet = {}
        for (const m of connected) connSet[m] = true

        const outputs = []

        if (activeType === "span") {
            const groups = spanGroups || []
            for (let i = 0; i < groups.length; ++i) {
                const g = groups[i]
                const raw = (g && g.monitors) ? g.monitors : []
                const seen = {}
                const monitors = []
                for (const m of raw) {
                    if (connSet[m] && !seen[m]) { seen[m] = true; monitors.push(m) }
                }
                if (monitors.length === 0) continue

                const key = "span:" + g.id
                if (monitors.length === 1) {
                    outputs.push({ key: key, kind: "single", monitors: monitors, owner: key, groupId: g.id })
                } else {
                    outputs.push({ key: key, kind: "span", monitors: monitors.slice().sort(), owner: key, groupId: g.id })
                }
            }
            return outputs
        }

        for (const m of connected) {
            const owner = resolveOwner(m)
            if (!owner) continue
            outputs.push({ key: m, kind: "single", monitors: [m], owner: owner })
        }
        return outputs
    }

    function screenArgsForOutput(output) {
        if (output.kind === "span") {
            return { mode: "span", flag: "screen-span", value: output.monitors.slice().sort().join(",") }
        }
        return { mode: "root", flag: "screen-root", value: output.monitors[0] }
    }

    function hasActivePlaylist(owner) {
        const p = ownerPlaylist(owner)
        return !!(p && p.length > 1)
    }

    function collectActiveOwners() {
        const outputs = computeOutputs()
        const owners = []
        const seen = {}
        for (const o of outputs) {
            if (ownerPlaylist(o.owner) && !seen[o.owner]) { seen[o.owner] = true; owners.push(o.owner) }
        }
        return owners
    }

    function normalizeOwner(monitor) {
        if (!monitor) return ""
        if (monitor === "*") return "*"
        const outputs = computeOutputs()
        for (const o of outputs) {
            if (o.monitors.indexOf(monitor) >= 0) return o.owner
        }
        return monitor
    }

    function bumpIndex(owner, direction) {
        const playlist = ownerPlaylist(owner)
        if (!playlist) return false
        let curIdx = playlistIndices[owner]
        if (curIdx === undefined || curIdx < 0 || curIdx >= playlist.length) curIdx = 0

        let nextIdx
        if (playlist.length === 1) {
            nextIdx = 0
        } else if (direction === 0 || playlistShuffle) {
            do { nextIdx = Math.floor(Math.random() * playlist.length) } while (nextIdx === curIdx)
        } else if (direction > 0) {
            nextIdx = (curIdx + 1) % playlist.length
        } else {
            nextIdx = (curIdx - 1 + playlist.length) % playlist.length
        }
        setPlaylistIndex(owner, nextIdx)
        return true
    }

    function syncScenesWithData() {
        if (!ready) return

        const outputs = computeOutputs()
        const outputKeys = {}
        for (const o of outputs) outputKeys[o.key] = true

        for (const key in processes) {
            if (!outputKeys[key]) stopOutput(key)
        }
        for (const key in pendingLaunches) {
            if (!outputKeys[key]) delete pendingLaunches[key]
        }
        for (const key in pendingKillers) {
            if (!outputKeys[key]) delete pendingKillers[key]
        }

        const audioSeen = {}

        for (const o of outputs) {
            const sceneId = ownerCurrentScene(o.owner)
            if (!sceneId) continue

            const settings = getOutputSettings(o.owner, sceneId)
            const wantsAudio = settings.silent === false
            let forceNoAudio = false
            if (wantsAudio) {
                if (audioSeen[sceneId]) forceNoAudio = true
                else audioSeen[sceneId] = true
            }

            const oldProc = processes[o.key]
            const oldSceneId = oldProc ? oldProc.sceneId : ""
            const oldSettings = (oldProc && oldProc.sceneId === oldSceneId) ? oldProc.settings : null
            const sceneChanged = sceneId !== oldSceneId
            const settingsChanged = !Utils.deepEqual(settings || {}, oldSettings || {})
            const forceNoAudioChanged = oldProc ? (!!oldProc.forceNoAudio !== !!forceNoAudio) : false
            // screen args changed (span monitor set changed, or span<->single degrade on hotplug): same output key, so re-launch or the wrong-mode process keeps running
            const oldSig = launchSignatures[o.key] || null
            const newSig = screenArgsForOutput(o)
            const screenArgsChanged = !Utils.deepEqual(oldSig || {}, newSig)
            const processNotRunning = !oldProc
            const isPending = pendingLaunches[o.key]

            if ((sceneChanged || settingsChanged || processNotRunning || forceNoAudioChanged || screenArgsChanged) && !isPending && !shouldPauseWallpaper) {
                launchOutput(o, sceneId, forceNoAudio)
            }
        }

        restartPlaylistTimers()
    }

    function startOutput(key, output, sceneId, forceNoAudio) {
        if (!root.ready || root.shouldPauseWallpaper) {
            delete pendingLaunches[key]
            return
        }

        const newSig = screenArgsForOutput(output)
        const useScreenshot = root.generateStaticWallpaper
        const settings = getOutputSettings(output.owner, sceneId)

        var screenshotPath = ""
        if (useScreenshot) {
            const outDir = root.screenshotDir()
            Quickshell.execDetached(["mkdir", "-p", outDir])
            if (output.kind === "span") {
                screenshotPath = outDir + "/span-" + (output.groupId || "x") + "-" + sceneId + ".jpg"
            } else {
                screenshotPath = outDir + "/" + output.monitors[0] + "-" + sceneId + ".jpg"
            }
        }

        const weProc = weProcessComponent.createObject(root, {
            screenMode: newSig.mode,
            screenValue: newSig.value,
            wallpaperMonitors: output.monitors,
            sceneId: sceneId,
            screenshotPath: screenshotPath,
            useScreenshot: useScreenshot,
            settings: settings,
            forceNoAudio: forceNoAudio
        })

        processes[key] = weProc
        launchSignatures[key] = newSig
        weProc.running = true
        delete pendingLaunches[key]

        if (useScreenshot) {
            const captureWaitMs = root.screenshotCaptureWaitMs(settings)
            if (output.kind === "span") {
                const crop = spanCropTimer.createObject(root, {
                    spanPath: screenshotPath,
                    monitors: output.monitors.slice(),
                    sceneId: sceneId,
                    delayMs: captureWaitMs
                })
                crop.running = true
            } else {
                const setWallpaper = setWallpaperTimer.createObject(root, {
                    wallpaperMonitors: output.monitors,
                    screenshotPath: screenshotPath,
                    delayMs: captureWaitMs
                })
                setWallpaper.running = true
            }
        }
    }

    function screenshotDir() {
        const cacheHome = StandardPaths.writableLocation(StandardPaths.GenericCacheLocation).toString()
        const baseDir = Paths.strip(cacheHome)
        return baseDir + "/DankMaterialShell/we_screenshots"
    }

    function screenshotCaptureWaitMs(sceneSettings) {
        const screenshotDelay = sceneSettings.screenshotDelay || 5
        const fps = sceneSettings.fps || 30
        return 1500 + Math.round((screenshotDelay / fps) * 1000)
    }

    function spanCropRects(monitors, sceneId) {
        const byName = {}
        for (const s of Quickshell.screens) byName[s.name] = s

        const sorted = monitors.slice().sort((a, b) => {
            const ax = byName[a] ? byName[a].x : 0
            const bx = byName[b] ? byName[b].x : 0
            return ax - bx
        })

        const outDir = root.screenshotDir()
        let xOffset = 0
        const rects = []
        for (const m of sorted) {
            const s = byName[m]
            const dpr = s ? (s.devicePixelRatio || 1) : 1
            const w = s ? Math.round(s.width * dpr) : 0
            const h = s ? Math.round(s.height * dpr) : 0
            rects.push({ monitor: m, path: outDir + "/" + m + "-" + sceneId + ".jpg", x: xOffset, w: w, h: h })
            xOffset += w
        }
        return rects
    }

    function applySpanScreenshot(spanPath, monitors, sceneId) {
        if (!SessionData.perMonitorWallpaper) {
            SessionData.setPerMonitorWallpaper(true)
        }
        if (!haveMagick) {
            console.warn("LinuxWallpaperEngine: magick not found; applying full span screenshot per monitor")
            for (const m of monitors) {
                SessionData.setMonitorWallpaper(m, spanPath)
            }
            return
        }
        const rects = root.spanCropRects(monitors, sceneId)
        for (const r of rects) {
            if (r.w <= 0 || r.h <= 0) continue
            Quickshell.execDetached(["magick", spanPath,
                "-crop", r.w + "x" + r.h + "+" + r.x + "+0", "+repage", r.path])
            const setWallpaper = setWallpaperTimer.createObject(root, {
                wallpaperMonitors: [r.monitor],
                screenshotPath: r.path,
                delayMs: 1500
            })
            setWallpaper.running = true
        }
    }

    function launchOutput(output, sceneId, forceNoAudio) {
        const key = output.key

        // a launch is already pending: retarget the waiting killer instead of dropping this request, so rapid changes don't lose the final state
        if (pendingLaunches[key] && pendingKillers[key]) {
            pendingKillers[key].output = output
            pendingKillers[key].sceneId = sceneId
            pendingKillers[key].forceNoAudio = forceNoAudio
            return
        }

        if (processes[key]) {
            processes[key].running = false
            processes[key].destroy()
            delete processes[key]
        }

        const oldSig = launchSignatures[key] || null
        if (!oldSig) {
            startOutput(key, output, sceneId, forceNoAudio)
            return
        }

        pendingLaunches[key] = true
        const killer = killerComponent.createObject(root, {
            key: key,
            killSig: oldSig,
            startNew: true,
            output: output,
            sceneId: sceneId,
            forceNoAudio: forceNoAudio
        })
        pendingKillers[key] = killer
        killer.running = true
    }

    function stopOutput(key) {
        // kill by PID, not pkill: a fresh process can reuse the same --screen-root signature and pkill would kill it too
        if (processes[key]) {
            const pid = processes[key].processId
            if (pid !== undefined && pid > 0) {
                Quickshell.execDetached(["kill", String(pid)])
            }
            processes[key].running = false
            processes[key].destroy()
            delete processes[key]
        }
        delete pendingLaunches[key]
        delete pendingKillers[key]
        delete launchSignatures[key]
    }

    function pauseOutputs() {
        paused = true
        playlistTimer.running = false
        for (const key in processes) {
            const proc = processes[key]
            if (proc) {
                const pid = proc.processId
                if (pid !== undefined && pid > 0) {
                    Quickshell.execDetached(["kill", "-STOP", String(pid)])
                }
            }
        }
    }

    function resumeOutputs() {
        paused = false
        const frozenKeys = []
        for (const key in processes) frozenKeys.push(key)
        syncScenesWithData()
        for (const key of frozenKeys) {
            const proc = processes[key]
            if (proc) {
                const pid = proc.processId
                if (pid !== undefined && pid > 0) {
                    Quickshell.execDetached(["kill", "-CONT", String(pid)])
                }
            }
        }
    }

    function stopAllOutputs() {
        for (const key in processes) {
            if (processes[key]) {
                processes[key].running = false
                processes[key].destroy()
            }
        }
        processes = ({})
        for (const key in launchSignatures) {
            const sig = launchSignatures[key]
            if (sig) {
                Quickshell.execDetached(["pkill", "-f", Utils.pkillPattern(sig)])
            }
        }
        launchSignatures = ({})
        pendingLaunches = ({})
        pendingKillers = ({})
        playlistTimer.running = false
    }

    function restartPlaylistTimers() {
        const owners = collectActiveOwners()
        const hasAny = owners.some(o => hasActivePlaylist(o))
        const enabled = hasAny && ready && !shouldPauseWallpaper && playlistIntervalMinutes > 0
        if (enabled) playlistTimer.interval = playlistIntervalMinutes * 60 * 1000
        playlistTimer.running = enabled
    }

    function toggle() {
        if (ready) {
            stopAllOutputs()
            ready = false
            console.info("LinuxWallpaperEngine: Toggled OFF")
        } else {
            prevGenerateStaticWallpaper = generateStaticWallpaper
            ready = true
            syncScenesWithData()
            console.info("LinuxWallpaperEngine: Toggled ON")
        }
    }

    function ipcAdvance(monitor, direction) {
        if (!ready) return "Wallpapers are toggled off"
        if (monitor) {
            const owner = normalizeOwner(monitor)
            if (!ownerPlaylist(owner)) return "No playlist for " + monitor
            bumpIndex(owner, direction)
        } else {
            const owners = collectActiveOwners()
            let n = 0
            for (const o of owners) {
                if (ownerPlaylist(o)) { bumpIndex(o, direction); n++ }
            }
            if (n === 0) return "No playlists configured"
        }
        syncScenesWithData()
        return "OK"
    }

    function ipcSet(sceneId, monitor) {
        if (!sceneId) return "ERROR: scene id required"
        if (!ready) return "Wallpapers are toggled off"
        if (!monitor) return "ERROR: monitor required"
        const owner = monitor === "*" ? "*" : monitor

        const scenes = Object.assign({}, pluginData.monitorScenes || {})
        scenes[owner] = sceneId
        if (pluginService && pluginService.savePluginData) {
            pluginService.savePluginData(pluginId, "monitorScenes", scenes)
            pluginService.savePluginData(pluginId, "activeType", "scene")
        }
        syncScenesWithData()
        return "Set " + owner + " to " + sceneId
    }

    function ipcList() {
        const outputs = computeOutputs()
        if (outputs.length === 0) return "No wallpapers active"
        return outputs.map(o => {
            const proc = processes[o.key]
            const sceneId = proc ? proc.sceneId : ownerCurrentScene(o.owner, false)
            const label = o.kind === "span" ? ("span[" + o.monitors.join(",") + "]") : o.monitors[0]
            return label + ": " + (sceneId || "none")
        }).join("\n")
    }

    // Quickshell's IpcHandler matches arg count exactly (no optional args), so each
    // "all monitors" vs "one monitor" form needs its own function.
    IpcHandler {
        target: "linuxWallpaperEngine"

        function next(): string { return root.ipcAdvance("", 1) }
        function prev(): string { return root.ipcAdvance("", -1) }
        function random(): string { return root.ipcAdvance("", 0) }
        function nextMonitor(monitor: string): string { return root.ipcAdvance(monitor, 1) }
        function prevMonitor(monitor: string): string { return root.ipcAdvance(monitor, -1) }
        function randomMonitor(monitor: string): string { return root.ipcAdvance(monitor, 0) }
        function set(sceneId: string, monitor: string): string { return root.ipcSet(sceneId, monitor) }
        function list(): string { return root.ipcList() }
    }

    Component {
        id: weProcessComponent

        Process {
            id: weProc

            property string screenMode: "root"
            property string screenValue: ""
            property var wallpaperMonitors: []
            property string sceneId: ""
            property string screenshotPath: ""
            property bool useScreenshot: false
            property var settings: ({})
            property bool forceNoAudio: false

            command: CommandBuilder.buildCommandArgs({
                screenMode: screenMode,
                screenValue: screenValue,
                sceneId: sceneId,
                useScreenshot: useScreenshot,
                screenshotPath: screenshotPath,
                settings: settings,
                forceNoAudio: forceNoAudio
            })

            onExited: (code) => {
                if (code !== 0) {
                    console.warn("LinuxWallpaperEngine: Process exited with code:", code, "for scene", sceneId, "on", screenValue)
                }
            }
        }
    }

    Component {
        id: killerComponent

        Process {
            property string key: ""
            property var killSig: null
            property bool startNew: false
            property var output: null
            property string sceneId: ""
            property bool forceNoAudio: false

            command: (killSig && killSig.flag)
                ? ["pkill", "-f", Utils.pkillPattern(killSig)]
                : ["true"]

            onExited: () => {
                if (startNew) {
                    root.startOutput(key, output, sceneId, forceNoAudio)
                }
                delete root.pendingKillers[key]
                destroy()
            }
        }
    }

    Component {
        id: spanCropTimer

        Timer {
            property string spanPath: ""
            property var monitors: []
            property string sceneId: ""
            property int delayMs: 1500

            running: false
            repeat: false
            interval: delayMs

            onTriggered: {
                if (!root.ready) { destroy(); return }
                root.applySpanScreenshot(spanPath, monitors, sceneId)
                destroy()
            }
        }
    }

    Component {
        id: setWallpaperTimer

        Timer {
            property var wallpaperMonitors: []
            property string screenshotPath: ""
            property int delayMs: 1500

            running: false
            repeat: false
            interval: delayMs

            onTriggered: {
                if (!SessionData.perMonitorWallpaper) {
                    SessionData.setPerMonitorWallpaper(true)
                }
                for (const m of wallpaperMonitors) {
                    console.info("LinuxWallpaperEngine: Set wp on", m, "to", screenshotPath)
                    SessionData.setMonitorWallpaper(m, screenshotPath)
                }
            }
        }
    }

    Timer {
        id: playlistTimer
        running: false
        repeat: true
        interval: playlistIntervalMinutes * 60 * 1000
        onTriggered: {
            const owners = collectActiveOwners()
            let bumped = false
            for (const owner of owners) {
                if (hasActivePlaylist(owner)) { bumpIndex(owner, 1); bumped = true }
            }
            if (bumped) syncScenesWithData()
        }
    }

    Component.onCompleted: {
        prevGenerateStaticWallpaper = generateStaticWallpaper
        ready = true
        console.info("LinuxWallpaperEngine: Plugin starting...")
        magickProbe.command = ["sh", "-c", "command -v magick >/dev/null 2>&1"]
        magickProbe.running = true
        syncScenesWithData()
    }

    Process {
        id: magickProbe
        onExited: (code) => { haveMagick = (code === 0) }
    }

    Component.onDestruction: {
        console.info("LinuxWallpaperEngine: Plugin stopping, cleaning up processes")

        for (const key in processes) {
            if (processes[key]) {
                processes[key].running = false
                processes[key].destroy()
            }
        }

        for (const key in launchSignatures) {
            const sig = launchSignatures[key]
            if (sig) {
                Quickshell.execDetached(["pkill", "-f", Utils.pkillPattern(sig)])
            }
        }
    }
}
