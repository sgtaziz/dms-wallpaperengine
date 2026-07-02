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

    // ---- config (bound to pluginData) ----
    property var monitorScenes: pluginData.monitorScenes || {}
    property var monitorPlaylists: pluginData.monitorPlaylists || {}
    // spanGroups: [ { id, monitors: [names], scene: <id>, playlist: [<ids>] } ]
    property var spanGroups: pluginData.spanGroups || []
    // outputSettings[owner] = { scaling, fps, silent, volume, screenshotDelay, disable* toggles }.
    // Render settings are per-output (monitor name / "*" / "span:<groupId>"), NOT per-scene.
    // Only scene properties (--set-property) stay per-scene, in sceneSettings.
    property var outputSettings: pluginData.outputSettings || {}
    // The ONE global active config type: "scene" | "playlist" | "span". Only this type's configs
    // render — the others are fully ignored (but stay saved). Set by the settings tab selection.
    property string activeType: pluginData.activeType || "scene"
    property bool playlistShuffle: pluginData.playlistShuffle || false
    property int playlistIntervalMinutes: Math.max(0, pluginData.playlistIntervalMinutes !== undefined ? pluginData.playlistIntervalMinutes : 5)
    property bool generateStaticWallpaper: pluginData.generateStaticWallpaper || false
    property bool prevGenerateStaticWallpaper: false
    property bool pauseOnPowerSaver: pluginData.pauseOnPowerSaver || false
    property bool pauseOnBattery: pluginData.pauseOnBattery || false

    // ---- runtime state ----
    // processes / launchSignatures / pendingLaunches are keyed by an "output key":
    //   - a monitor name for a single --screen-root output, or
    //   - "span:<groupId>" for a multi-monitor --screen-span output.
    property var processes: ({})
    property var launchSignatures: ({})   // outputKey -> { flag, value } of the running process (for precise pkill)
    property var playlistIndices: ({})    // owner -> current playlist index
    property var pendingLaunches: ({})    // outputKey -> true while a (re)launch is in flight
    property var pendingKillers: ({})     // outputKey -> killer Process awaiting relaunch (so its target can be updated)
    property bool ready: false
    // whether ImageMagick (`magick`) is available for cropping span screenshots per monitor
    property bool haveMagick: false
    // true when outputs are SIGSTOPped (power/battery pause): processes stay alive with their
    // last rendered frame frozen on screen, but use no CPU. Resume via SIGCONT — no relaunch.
    property bool paused: false

    readonly property bool shouldPauseWallpaper: {
        if (pauseOnPowerSaver && typeof PowerProfiles !== "undefined" && PowerProfiles.profile === PowerProfile.PowerSaver) return true
        if (pauseOnBattery && BatteryService.batteryAvailable && !BatteryService.isPluggedIn) return true
        return false
    }

    // first connected screen; used as the default target for the IPC `set` command
    property string mainMonitor: {
        const monitors = Quickshell.screens.map(s => s.name)
        if (monitors.length > 0) return monitors[0]
        const keys = Object.keys(monitorScenes).filter(k => k !== "*")
        return keys.length > 0 ? keys[0] : ""
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

    // Display hotplug (connect/disconnect) -> recompute outputs via the normal sync path.
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
            // toggling screenshots changes every launch command, so restart everything
            stopAllOutputs()
            syncScenesWithData()
        }
    }

    // ============================ helpers ============================

    function escapeRegex(str) {
        return String(str).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    }

    // pkill pattern matching a single output's process. The trailing "($| )" boundary
    // prevents a value that is a prefix of another's from matching both (e.g.
    // "--screen-span HDMI-1,HDMI-2" must not also match "--screen-span HDMI-1,HDMI-2,HDMI-3").
    function pkillPattern(sig) {
        return ".*linux-wallpaperengine.*--" + sig.flag + " " + escapeRegex(sig.value) + "($| )"
    }

    function deepEqual(a, b) {
        if (a === b) return true
        if (a === null || b === null) return false
        if (typeof a !== "object" || typeof b !== "object") return false

        const aIsArray = Array.isArray(a)
        const bIsArray = Array.isArray(b)
        if (aIsArray !== bIsArray) return false

        if (aIsArray) {
            if (a.length !== b.length) return false
            for (let i = 0; i < a.length; ++i) if (!deepEqual(a[i], b[i])) return false
            return true
        }

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

    function getSceneSettings(sceneId) {
        const allSettings = pluginData.sceneSettings || {}
        return allSettings[sceneId] || {}
    }

    // Merged settings object the command builder consumes for a given output. Render settings
    // (scaling/fps/volume/etc.) are per-output (keyed by owner); only `properties` (--set-property,
    // intrinsic to the scene) comes from per-scene sceneSettings. Owner is a monitor name, "*",
    // or "span:<groupId>". No defaults applied here — the command builder supplies them.
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

    // ---- owner resolution -------------------------------------------------
    // An "owner" is the source of a scene/playlist for an output. It is one of:
    //   - a monitor name (explicit per-monitor config)
    //   - "*" (the "All Monitors" default)
    //   - "span:<groupId>" (a span group)
    // playlist for an owner (monitor/"*"/"span:<id>"). Null if none.
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

    // does this owner have a config OF THE ACTIVE TYPE? The global activeType decides which kind
    // of config is rendered; the others are dormant.
    function hasConfig(owner) {
        if (!owner) return false
        if (activeType === "span") {
            // only span owners are relevant in span mode (handled directly in computeOutputs)
            return false
        }
        if (activeType === "scene") {
            return !!ownerStaticScene(owner)
        }
        // playlist mode: configured if there's a playlist (static scene alone is not a playlist)
        return !!ownerPlaylist(owner)
    }

    function setPlaylistIndex(owner, idx) {
        const indices = Object.assign({}, playlistIndices)
        indices[owner] = idx
        playlistIndices = indices
    }

    // current effective scene for an owner, respecting the global active type:
    //   - scene mode (monitor/"*"): the static scene (a stored playlist is dormant)
    //   - playlist mode (monitor/"*"): the playlist's current scene
    //   - span owners: playlist scene if the group has a rotation, else its static scene
    // pass persist=false for read-only lookups (e.g. listing) so shuffle doesn't mutate state.
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

    // owner for a bare monitor in the active (non-span) type: itself if it has explicit config,
    // else "*" if set, else "".
    function resolveOwner(monitor) {
        if (hasConfig(monitor)) return monitor
        if (hasConfig("*")) return "*"
        return ""
    }

    // ---- output computation ----------------------------------------------
    // An "output" is one wallpaper process. Returns descriptors:
    //   { key, kind: "single"|"span", monitors: [...], owner, groupId? }
    // Only the GLOBAL activeType's configs render:
    //   - "scene"  -> per-monitor static scenes (+ "*" default), one --screen-root each
    //   - "playlist" -> per-monitor playlists (+ "*"), one --screen-root each
    //   - "span"   -> span groups only (one --screen-span each; 1-monitor groups degrade to root)
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

        // scene or playlist mode: one --screen-root per monitor, resolved via the active type
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

    // distinct owners among currently-active outputs that have a playlist
    function collectActiveOwners() {
        const outputs = computeOutputs()
        const owners = []
        const seen = {}
        for (const o of outputs) {
            if (ownerPlaylist(o.owner) && !seen[o.owner]) { seen[o.owner] = true; owners.push(o.owner) }
        }
        return owners
    }

    // map a monitor name (or "*") passed via IPC to its effective owner
    function normalizeOwner(monitor) {
        if (!monitor) return ""
        if (monitor === "*") return "*"
        const outputs = computeOutputs()
        for (const o of outputs) {
            if (o.monitors.indexOf(monitor) >= 0) return o.owner
        }
        return monitor
    }

    // advance/rewind/randomize an owner's playlist index
    // direction: 1 = next, -1 = prev, 0 = random
    function bumpIndex(owner, direction) {
        const playlist = ownerPlaylist(owner)
        if (!playlist) return false
        let curIdx = playlistIndices[owner]
        if (curIdx === undefined || curIdx < 0 || curIdx >= playlist.length) curIdx = 0

        let nextIdx
        if (playlist.length === 1) {
            nextIdx = 0
        } else if (direction === 0 || playlistShuffle) {
            // shuffle mode (or explicit random) -> pick a different entry
            do { nextIdx = Math.floor(Math.random() * playlist.length) } while (nextIdx === curIdx)
        } else if (direction > 0) {
            nextIdx = (curIdx + 1) % playlist.length
        } else {
            nextIdx = (curIdx - 1 + playlist.length) % playlist.length
        }
        setPlaylistIndex(owner, nextIdx)
        return true
    }

    // ============================ sync ============================

    function syncScenesWithData() {
        if (!ready) return

        const outputs = computeOutputs()
        const outputKeys = {}
        for (const o of outputs) outputKeys[o.key] = true

        // stop outputs that no longer exist (disconnected monitor, removed group, etc.)
        for (const key in processes) {
            if (!outputKeys[key]) stopOutput(key)
        }
        for (const key in pendingLaunches) {
            if (!outputKeys[key]) delete pendingLaunches[key]
        }
        for (const key in pendingKillers) {
            if (!outputKeys[key]) delete pendingKillers[key]
        }

        // audio de-dup: only the first output showing a given (audio-enabled) scene plays sound.
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
            const settingsChanged = !deepEqual(settings || {}, oldSettings || {})
            const forceNoAudioChanged = oldProc ? (!!oldProc.forceNoAudio !== !!forceNoAudio) : false
            // screen args changed: e.g. a span group's monitor set changed, or it degraded
            // between span and single output on hotplug. The output key stays the same, so
            // without this the wrong-mode process would keep running.
            const oldSig = launchSignatures[o.key] || null
            const newSig = screenArgsForOutput(o)
            const screenArgsChanged = !deepEqual(oldSig || {}, newSig)
            const processNotRunning = !oldProc
            const isPending = pendingLaunches[o.key]

            if ((sceneChanged || settingsChanged || processNotRunning || forceNoAudioChanged || screenArgsChanged) && !isPending && !shouldPauseWallpaper) {
                launchOutput(o, sceneId, forceNoAudio)
            }
        }

        restartPlaylistTimers()
    }

    // ============================ launch / stop ============================

    // Build & start the wallpaper process for an output (no killing). Computes the screen args,
    // records the launch signature, and arms the static-wallpaper screenshot timer if enabled.
    function startOutput(key, output, sceneId, forceNoAudio) {
        if (!root.ready || root.shouldPauseWallpaper) {
            delete pendingLaunches[key]
            return
        }

        const newSig = screenArgsForOutput(output)
        const useScreenshot = root.generateStaticWallpaper
        const settings = getOutputSettings(output.owner, sceneId)

        // Static-screenshot strategy:
        //  - single-monitor output: the live process captures its own screenshot as a side effect
        //    ("<monitor>-<sceneId>.jpg"); --screenshot doesn't make it exit, which is what we want.
        //  - span output: the live --screen-span process captures ONE wide screenshot covering the
        //    whole span, then we crop it per monitor (each monitor's copy sits side-by-side at its
        //    own resolution, left-to-right by screen x-position) into "<monitor>-<sceneId>.jpg".
        var screenshotPath = ""
        if (useScreenshot) {
            const outDir = root.screenshotDir()
            Quickshell.execDetached(["mkdir", "-p", outDir])
            if (output.kind === "span") {
                // one shared wide image; cropped per monitor after capture. keyed by group id so
                // different span groups (even sharing a scene) don't clobber each other's file.
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
                // wait for the wide screenshot to be written, then crop per monitor and apply
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

    // ms to wait for the live process to load the scene, render `screenshotDelay` frames, and
    // write the screenshot file before we crop/apply it. Scene load (~1.5s) + the delay frames.
    function screenshotCaptureWaitMs(sceneSettings) {
        const screenshotDelay = sceneSettings.screenshotDelay || 5
        const fps = sceneSettings.fps || 30
        return 1500 + Math.round((screenshotDelay / fps) * 1000)
    }

    // Per-monitor crop rectangles for a span screenshot. The engine lays each monitor's copy
    // side-by-side left-to-right by screen position (xdg-output x), each at its own native
    // resolution, top-aligned. Returns [{ monitor, path, x, w, h }] in left-to-right order,
    // where x is the pixel offset into the wide image, w/h that monitor's physical pixel size.
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

    // Crop the wide span screenshot into one file per monitor and set each as that monitor's
    // static wallpaper. Uses ImageMagick (`magick`). If magick is unavailable, falls back to
    // applying the whole wide image to every monitor (better than nothing).
    function applySpanScreenshot(spanPath, monitors, sceneId) {
        if (!SessionData.perMonitorWallpaper) {
            SessionData.setPerMonitorWallpaper(true)
        }
        if (!haveMagick) {
            // no ImageMagick -> can't crop; apply the whole wide image to each monitor
            console.warn("LinuxWallpaperEngine: magick not found; applying full span screenshot per monitor")
            for (const m of monitors) {
                SessionData.setMonitorWallpaper(m, spanPath)
            }
            return
        }
        const rects = root.spanCropRects(monitors, sceneId)
        for (const r of rects) {
            if (r.w <= 0 || r.h <= 0) continue
            // magick in.jpg -crop WxH+X+0 +repage out.jpg
            Quickshell.execDetached(["magick", spanPath,
                "-crop", r.w + "x" + r.h + "+" + r.x + "+0", "+repage", r.path])
            console.info("LinuxWallpaperEngine: Cropped span ->", r.path)
            SessionData.setMonitorWallpaper(r.monitor, r.path)
        }
    }

    function launchOutput(output, sceneId, forceNoAudio) {
        const key = output.key

        // If a launch is already pending for this key (a killer is waiting to relaunch), don't
        // drop the new request — update the pending killer's target so when it fires it launches
        // the LATEST config. Without this, rapid tab/scene changes lose the final state.
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
            // nothing running to kill -> start immediately
            startOutput(key, output, sceneId, forceNoAudio)
            return
        }

        // wait for the previous process to actually die before relaunching
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
        // Kill the old process by PID (not pkill-by-command-line). A command-line pkill can match
        // a freshly-launched process that happens to reuse the same --screen-root <monitor>
        // signature (e.g. a 1-monitor span group degrading to --screen-root eDP-1 right after a
        // scene-mode process on eDP-1 was stopped), killing the new process too. PID is precise.
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

    // Freeze every live wallpaper process in place (SIGSTOP) without tearing it down. The
    // compositor keeps the last rendered frame on screen, like pausing a video, while the
    // process consumes no CPU. Paired with resumeOutputs() (SIGCONT).
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

    // Thaw processes frozen by pauseOutputs() and reconcile state: anything that changed while
    // paused (scene/setting/monitor edits, hotplug) is applied; surviving outputs get SIGCONT.
    function resumeOutputs() {
        paused = false
        // sync first: it stops outputs that no longer apply and launches new ones; for outputs
        // that are unchanged it will SIGCONT the still-frozen process below.
        const frozenKeys = []
        for (const key in processes) frozenKeys.push(key)
        syncScenesWithData()
        // any of the originally-frozen processes that survived sync are still STOPped -> resume
        for (const key of frozenKeys) {
            const proc = processes[key]
            if (proc) {
                const pid = proc.processId
                if (pid !== undefined && pid > 0) {
                    Quickshell.execDetached(["kill", "-CONT", String(pid)])
                }
            }
        }
        // syncScenesWithData() already restarted the playlist timer if appropriate
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
                Quickshell.execDetached(["pkill", "-f", pkillPattern(sig)])
            }
        }
        launchSignatures = ({})
        pendingLaunches = ({})
        pendingKillers = ({})
        playlistTimer.running = false
    }

    // ============================ playlist timer ============================

    function restartPlaylistTimers() {
        const owners = collectActiveOwners()
        const hasAny = owners.some(o => hasActivePlaylist(o))
        // interval 0 = IPC-only swapping (no auto-advance); don't run the timer in that case
        const enabled = hasAny && ready && !shouldPauseWallpaper && playlistIntervalMinutes > 0
        if (enabled) playlistTimer.interval = playlistIntervalMinutes * 60 * 1000
        playlistTimer.running = enabled
    }

    // ============================ toggle ============================

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

    // ============================ IPC (scene rotation) ============================
    // On/off is handled by DMS: `dms ipc call plugins toggle linuxWallpaperEngine`.
    // The handler below exposes scene rotation / inspection.

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

    function ipcSet(a, b) {
        if (!a) return "ERROR: scene id required"
        if (!ready) return "Wallpapers are toggled off"
        // Accept either `set <sceneId> [monitor]` or `set <monitor> <sceneId>`: if the first arg
        // is a connected monitor name (or "*"), treat it as the monitor and the second as sceneId.
        var sceneId, monitor
        const connected = {}
        for (const m of connectedMonitors()) connected[m] = true
        if (a === "*" || connected[a]) {
            monitor = a
            sceneId = b
        } else {
            sceneId = a
            monitor = b
        }
        if (!sceneId) return "ERROR: scene id required"
        // IPC set always targets a single monitor (or "*" / mainMonitor) with a static scene.
        // It switches the global active type to "scene" so the set actually renders.
        const owner = monitor ? (monitor === "*" ? "*" : monitor) : mainMonitor
        if (!owner) return "ERROR: no monitor"

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
            // prefer the actually-running scene; fall back to a non-mutating resolve
            const proc = processes[o.key]
            const sceneId = proc ? proc.sceneId : ownerCurrentScene(o.owner, false)
            const label = o.kind === "span" ? ("span[" + o.monitors.join(",") + "]") : o.monitors[0]
            return label + ": " + (sceneId || "none")
        }).join("\n")
    }

    IpcHandler {
        target: "linuxWallpaperEngine"

        function next(monitor: string): string { return root.ipcAdvance(monitor, 1) }
        function prev(monitor: string): string { return root.ipcAdvance(monitor, -1) }
        function random(monitor: string): string { return root.ipcAdvance(monitor, 0) }
        function set(sceneId: string, monitor: string): string { return root.ipcSet(sceneId, monitor) }
        function list(): string { return root.ipcList() }
    }

    // ============================ process components ============================

    Component {
        id: weProcessComponent

        Process {
            id: weProc

            property string screenMode: "root"   // "root" (--screen-root) or "span" (--screen-span)
            property string screenValue: ""       // monitor name, or "m1,m2,..." for a span
            property var wallpaperMonitors: []    // monitors covered (used to set static wallpaper)
            property string sceneId: ""
            property string screenshotPath: ""
            property bool useScreenshot: false
            property var settings: ({})
            property bool forceNoAudio: false

            command: {
                var args = ["linux-wallpaperengine"]

                if (screenMode === "span") {
                    args.push("--screen-span")
                } else {
                    args.push("--screen-root")
                }
                args.push(screenValue)

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
                    if (volume === undefined || volume === null) volume = 50
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
                    console.warn("LinuxWallpaperEngine: Process exited with code:", code, "for scene", sceneId, "on", screenValue)
                }
            }
        }
    }

    Component {
        id: killerComponent

        Process {
            property string key: ""
            property var killSig: null        // { flag, value } of the process to pkill (always provided)
            property bool startNew: false
            property var output: null
            property string sceneId: ""
            property bool forceNoAudio: false

            command: (killSig && killSig.flag)
                ? ["pkill", "-f", root.pkillPattern(killSig)]
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

    // Throwaway process used only to capture a per-monitor screenshot for spanned monitors.
    // After the live --screen-span process has written its wide screenshot, crop it per monitor
    // and apply each as that monitor's static wallpaper.
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
                Quickshell.execDetached(["pkill", "-f", pkillPattern(sig)])
            }
        }
    }
}
