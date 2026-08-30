import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "ui"
import "js/Utils.js" as Utils
import "js/CommandBuilder.js" as CommandBuilder

PluginComponent {
    id: root

    property var monitorScenes: pluginData.monitorScenes || {}
    property var monitorPlaylists: pluginData.monitorPlaylists || {}
    property var namedPlaylists: pluginData.namedPlaylists || ({})
    property var namedPlaylistSettings: pluginData.namedPlaylistSettings || ({})
    property var activePlaylistNames: pluginData.activePlaylistNames || ({})
    property var pickerScrollPositions: pluginData.pickerScrollPositions || ({})
    property var spanGroups: pluginData.spanGroups || []
    property var outputSettings: pluginData.outputSettings || {}
    property string activeType: pluginData.activeType || "scene"
    property bool playlistShuffle: pluginData.playlistShuffle || false
    property int playlistIntervalMinutes: Math.max(0, pluginData.playlistIntervalMinutes !== undefined ? pluginData.playlistIntervalMinutes : 5)
    property bool generateStaticWallpaper: pluginData.generateStaticWallpaper || false
    property bool prevGenerateStaticWallpaper: false
    property bool pauseOnPowerSaver: pluginData.pauseOnPowerSaver || false
    property bool pauseOnBattery: pluginData.pauseOnBattery || false
    property string assetsDir: pluginData.assetsDir || ""
    property string backgroundsDir: pluginData.backgroundsDir || ""
    property string pickerTargetMonitor: "*"
    property bool pickerOpen: false

    property var processes: ({})
    property var launchSignatures: ({})
    property var playlistIndices: ({})
    property var pendingLaunches: ({})
    property var pendingKillers: ({})
    property bool ready: false
    property bool haveMagick: false
    property bool paused: false

    property var steamPaths: {
        var homePath = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString()
        if (homePath.startsWith("file://")) {
            homePath = homePath.substring(7)
        }

        return [
            homePath + "/.local/share/Steam/steamapps/workshop/content/431960",
            homePath + "/.steam/steam/steamapps/workshop/content/431960",
            homePath + "/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960",
            homePath + "/.snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960"
        ]
    }
    property string steamWorkshopPath: steamPaths[0]
    property int currentPathIndex: 0

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

    Timer {
        id: processRestartTimer
        interval: 2000
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

    // assetsDir is global, not part of per-output settings, so the per-output change detection in
    // syncScenesWithData won't catch it. Force a relaunch so running processes pick up the new path.
    onAssetsDirChanged: {
        if (!ready) return
        stopAllOutputs()
        syncScenesWithData()
    }

    // Same reasoning: backgroundsDir changes how scene ids resolve to --bg, so relaunch everything.
    onBackgroundsDirChanged: {
        if (!ready) return
        stopAllOutputs()
        syncScenesWithData()
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

    function discoverSteamPath() {
        currentPathIndex = 0
        checkNextPath()
    }

    function checkNextPath() {
        if (currentPathIndex >= steamPaths.length) {
            return
        }

        const testPath = steamPaths[currentPathIndex]
        pathCheckProcess.testPath = testPath
        pathCheckProcess.command = ["test", "-d", testPath]
        pathCheckProcess.running = true
    }

    function setSceneForOwner(sceneId, owner) {
        if (!sceneId || !pluginService || !pluginService.savePluginData) return false
        const scenes = Object.assign({}, pluginData.monitorScenes || {})
        const target = owner || "*"
        scenes[target] = sceneId
        if (target === "*") {
            for (const monitor of connectedMonitors()) delete scenes[monitor]
        }
        monitorScenes = scenes
        activeType = "scene"
        console.info("LinuxWallpaperEngine: Applying scene", sceneId, "to", target)
        pluginService.savePluginData(pluginId, "monitorScenes", scenes)
        pluginService.savePluginData(pluginId, "activeType", "scene")
        stopAllOutputs()
        syncScenesWithData()
        return true
    }

    function playlistForOwner(owner) {
        const playlists = monitorPlaylists || {}
        const list = playlists[owner || "*"]
        return Array.isArray(list) ? list : []
    }

    function ensureNamedPlaylists(owner) {
        let lists = Object.assign({}, namedPlaylists || pluginData.namedPlaylists || {})
        if (lists.Default === undefined) {
            const legacy = playlistForOwner(owner || "*")
            lists.Default = Object.keys(lists).length === 0 ? legacy.slice() : []
            namedPlaylists = lists
            pluginService.savePluginData(pluginId, "namedPlaylists", lists)
        }
        return lists
    }

    function createNamedPlaylist(name) {
        const clean = String(name || "").trim()
        if (!clean || !pluginService || !pluginService.savePluginData) return false
        const lists = Object.assign({}, ensureNamedPlaylists(pickerTargetMonitor))
        if (lists[clean] !== undefined) return false
        lists[clean] = []
        namedPlaylists = lists
        pluginService.savePluginData(pluginId, "namedPlaylists", lists)
        const settings = Object.assign({}, namedPlaylistSettings)
        settings[clean] = { intervalMinutes: playlistIntervalMinutes, shuffle: playlistShuffle }
        namedPlaylistSettings = settings
        pluginService.savePluginData(pluginId, "namedPlaylistSettings", settings)
        wallpaperPicker.namedPlaylists = lists
        wallpaperPicker.namedPlaylistSettings = settings
        wallpaperPicker.selectPlaylist(clean)
        console.info("LinuxWallpaperEngine: Created playlist", clean)
        return true
    }

    function deleteNamedPlaylist(name) {
        const lists = Object.assign({}, ensureNamedPlaylists(pickerTargetMonitor))
        if (!name || name === "Default" || lists[name] === undefined || Object.keys(lists).length <= 1) return false
        const ordered = Object.keys(lists).sort((a, b) => a.localeCompare(b))
        const deletedIndex = ordered.indexOf(name)
        delete lists[name]
        const settings = Object.assign({}, namedPlaylistSettings)
        delete settings[name]
        const activeNames = Object.assign({}, activePlaylistNames)
        for (const owner in activeNames) {
            if (activeNames[owner] === name) delete activeNames[owner]
        }
        namedPlaylists = lists
        namedPlaylistSettings = settings
        activePlaylistNames = activeNames
        pluginService.savePluginData(pluginId, "namedPlaylists", lists)
        pluginService.savePluginData(pluginId, "namedPlaylistSettings", settings)
        pluginService.savePluginData(pluginId, "activePlaylistNames", activeNames)
        wallpaperPicker.namedPlaylists = lists
        wallpaperPicker.namedPlaylistSettings = settings
        wallpaperPicker.activePlaylistName = activeNames[pickerTargetMonitor] || ""
        const remaining = ordered.filter(item => item !== name)
        const nextIndex = Math.max(0, Math.min(remaining.length - 1, deletedIndex - 1))
        wallpaperPicker.selectPlaylist(remaining[nextIndex] || "Default")
        return true
    }

    function addSceneToNamedPlaylist(sceneId, name) {
        if (!sceneId || !name || !pluginService || !pluginService.savePluginData) return false
        const lists = Object.assign({}, ensureNamedPlaylists(pickerTargetMonitor))
        const list = Array.isArray(lists[name]) ? lists[name].slice() : []
        if (list.indexOf(sceneId) < 0) list.push(sceneId)
        lists[name] = list
        namedPlaylists = lists
        pluginService.savePluginData(pluginId, "namedPlaylists", lists)
        wallpaperPicker.namedPlaylists = lists
        wallpaperPicker.playlistSceneIds = list
        const target = pickerTargetMonitor || "*"
        if (activePlaylistNames[target] === name) {
            const monitorLists = Object.assign({}, monitorPlaylists)
            monitorLists[target] = list.slice()
            monitorPlaylists = monitorLists
            pluginService.savePluginData(pluginId, "monitorPlaylists", monitorLists)
            if (activeType === "playlist") syncScenesWithData()
        }
        console.info("LinuxWallpaperEngine: Added scene", sceneId, "to playlist", name)
        return true
    }

    function useNamedPlaylistForOwner(name, owner) {
        const target = owner || "*"
        const lists = ensureNamedPlaylists(target)
        const list = Array.isArray(lists[name]) ? lists[name].slice() : []
        if (!name || list.length === 0 || !pluginService || !pluginService.savePluginData) return false
        const playlists = Object.assign({}, monitorPlaylists || {})
        const activeNames = Object.assign({}, activePlaylistNames || {})
        playlists[target] = list
        activeNames[target] = name
        monitorPlaylists = playlists
        activePlaylistNames = activeNames
        activeType = "playlist"
        const settings = namedPlaylistSettings[name] || {}
        playlistIntervalMinutes = Math.max(0, Number(settings.intervalMinutes !== undefined ? settings.intervalMinutes : 5))
        playlistShuffle = settings.shuffle === true
        pluginService.savePluginData(pluginId, "monitorPlaylists", playlists)
        pluginService.savePluginData(pluginId, "activePlaylistNames", activeNames)
        pluginService.savePluginData(pluginId, "activeType", "playlist")
        pluginService.savePluginData(pluginId, "playlistIntervalMinutes", playlistIntervalMinutes)
        pluginService.savePluginData(pluginId, "playlistShuffle", playlistShuffle)
        syncScenesWithData()
        return true
    }

    function saveNamedPlaylistSettings(name, intervalMinutes, shuffle) {
        if (!name || !pluginService || !pluginService.savePluginData) return false
        const allSettings = Object.assign({}, namedPlaylistSettings)
        allSettings[name] = {
            intervalMinutes: Math.max(0, Number(intervalMinutes)),
            shuffle: shuffle === true
        }
        namedPlaylistSettings = allSettings
        pluginService.savePluginData(pluginId, "namedPlaylistSettings", allSettings)
        wallpaperPicker.namedPlaylistSettings = allSettings

        const target = pickerTargetMonitor || "*"
        if (activePlaylistNames[target] === name) {
            playlistIntervalMinutes = allSettings[name].intervalMinutes
            playlistShuffle = allSettings[name].shuffle
            pluginService.savePluginData(pluginId, "playlistIntervalMinutes", playlistIntervalMinutes)
            pluginService.savePluginData(pluginId, "playlistShuffle", playlistShuffle)
            restartPlaylistTimers()
        }
        return true
    }

    function removeSceneFromNamedPlaylist(sceneId, name) {
        if (!sceneId || !name || !pluginService || !pluginService.savePluginData) return false
        const lists = Object.assign({}, ensureNamedPlaylists(pickerTargetMonitor))
        const list = (Array.isArray(lists[name]) ? lists[name] : []).filter(s => s !== sceneId)
        lists[name] = list
        namedPlaylists = lists
        pluginService.savePluginData(pluginId, "namedPlaylists", lists)
        wallpaperPicker.namedPlaylists = lists
        wallpaperPicker.namedPlaylistSettings = namedPlaylistSettings
        wallpaperPicker.playlistSceneIds = list
        const target = pickerTargetMonitor || "*"
        if (activePlaylistNames[target] === name) {
            const monitorLists = Object.assign({}, monitorPlaylists)
            monitorLists[target] = list.slice()
            monitorPlaylists = monitorLists
            pluginService.savePluginData(pluginId, "monitorPlaylists", monitorLists)
            if (activeType === "playlist") syncScenesWithData()
        }
        return true
    }

    function openPicker(monitor) {
        if (pickerOpen) {
            wallpaperPicker.close()
            pickerOpen = false
            return
        }
        pickerTargetMonitor = monitor || "*"
        pickerOpen = true
        const lists = ensureNamedPlaylists(pickerTargetMonitor)
        const names = Object.keys(lists).sort()
        const preferred = activePlaylistNames[pickerTargetMonitor] || names[0] || ""
        wallpaperPicker.namedPlaylists = lists
        wallpaperPicker.namedPlaylistSettings = namedPlaylistSettings
        wallpaperPicker.activePlaylistName = activePlaylistNames[pickerTargetMonitor] || ""
        wallpaperPicker.scrollPositions = pickerScrollPositions
        wallpaperPicker.selectedPlaylistName = preferred
        wallpaperPicker.playlistSceneIds = preferred && Array.isArray(lists[preferred]) ? lists[preferred].slice() : []
        wallpaperPicker.currentSceneId = ownerStaticScene(pickerTargetMonitor)
        wallpaperPicker.showLibrary()
        wallpaperPicker.open()
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
            outputKey: key,
            screenMode: newSig.mode,
            screenValue: newSig.value,
            wallpaperMonitors: output.monitors,
            sceneId: sceneId,
            screenshotPath: screenshotPath,
            useScreenshot: useScreenshot,
            settings: settings,
            forceNoAudio: forceNoAudio,
            isNiri: CompositorService.isNiri,
            assetsDir: root.assetsDir,
            backgroundsDir: root.backgroundsDir
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

        return setSceneForOwner(sceneId, owner) ? ("Set " + owner + " to " + sceneId) : "ERROR: could not save scene"
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
        function picker(): string { root.openPicker("*"); return "OK" }
        function pickerMonitor(monitor: string): string { root.openPicker(monitor); return "OK" }
        function playlistAdd(name: string, sceneId: string): string { return root.addSceneToNamedPlaylist(sceneId, name) ? "OK" : "ERROR" }
        function playlistCreate(name: string): string { return root.createNamedPlaylist(name) ? "OK" : "ERROR" }
        function playlistDelete(name: string): string { return root.deleteNamedPlaylist(name) ? "OK" : "ERROR" }
        function playlistRemove(name: string, sceneId: string): string { return root.removeSceneFromNamedPlaylist(sceneId, name) ? "OK" : "ERROR" }
        function playlistUse(name: string, monitor: string): string { return root.useNamedPlaylistForOwner(name, monitor) ? "OK" : "ERROR" }
    }

    Component {
        id: weProcessComponent

        Process {
            id: weProc

            property string outputKey: ""
            property string screenMode: "root"
            property string screenValue: ""
            property var wallpaperMonitors: []
            property string sceneId: ""
            property string screenshotPath: ""
            property bool useScreenshot: false
            property var settings: ({})
            property bool forceNoAudio: false
            property bool isNiri: false
            property string assetsDir: ""
            property string backgroundsDir: ""

            command: CommandBuilder.buildCommandArgs({
                screenMode: screenMode,
                screenValue: screenValue,
                sceneId: sceneId,
                useScreenshot: useScreenshot,
                screenshotPath: screenshotPath,
                settings: settings,
                forceNoAudio: forceNoAudio,
                isNiri: isNiri,
                assetsDir: assetsDir,
                backgroundsDir: backgroundsDir
            })

            onExited: (code) => {
                if (code !== 0) {
                    console.warn("LinuxWallpaperEngine: Process exited with code:", code, "for scene", sceneId, "on", screenValue)
                }
                if (root.processes[outputKey] === weProc) {
                    delete root.processes[outputKey]
                    delete root.launchSignatures[outputKey]
                    if (root.ready && !root.shouldPauseWallpaper && !useScreenshot) {
                        processRestartTimer.restart()
                    }
                    destroy()
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
            if (!ready || shouldPauseWallpaper) return
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
        if (CompositorService.isNiri) {
            console.info("LinuxWallpaperEngine: niri detected, using background layer")
        }
        discoverSteamPath()
        ensureNamedPlaylists("*")
        magickProbe.command = ["sh", "-c", "command -v magick >/dev/null 2>&1"]
        magickProbe.running = true
        syncScenesWithData()
    }

    Process {
        id: magickProbe
        onExited: (code) => { haveMagick = (code === 0) }
    }

    Process {
        id: pathCheckProcess
        property string testPath: ""

        onExited: (code) => {
            if (code === 0) {
                steamWorkshopPath = testPath
            } else {
                currentPathIndex++
                checkNextPath()
            }
        }
    }

    WallpaperPickerModal {
        id: wallpaperPicker
        steamWorkshopPath: root.steamWorkshopPath
        customBackgroundsPath: root.backgroundsDir

        onDialogClosed: {
            root.pickerOpen = false
        }

        onSceneApplied: (sceneId) => {
            root.pickerOpen = false
            root.setSceneForOwner(sceneId, root.pickerTargetMonitor || "*")
        }

        onSceneAddedToPlaylist: (sceneId, playlistName) => {
            root.addSceneToNamedPlaylist(sceneId, playlistName)
        }

        onSceneRemovedFromPlaylist: (sceneId, playlistName) => {
            root.removeSceneFromNamedPlaylist(sceneId, playlistName)
        }

        onPlaylistCreated: (name) => {
            root.createNamedPlaylist(name)
        }

        onPlaylistDeleted: (name) => {
            root.deleteNamedPlaylist(name)
        }

        onPlaylistSettingsChanged: (name, intervalMinutes, shuffle) => {
            root.saveNamedPlaylistSettings(name, intervalMinutes, shuffle)
        }

        onScrollPositionsSaved: (positions) => {
            root.pickerScrollPositions = positions
            root.pluginService.savePluginData(root.pluginId, "pickerScrollPositions", positions)
        }

        onPlaylistActivated: (name) => {
            root.pickerOpen = false
            root.useNamedPlaylistForOwner(name, root.pickerTargetMonitor || "*")
        }
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
