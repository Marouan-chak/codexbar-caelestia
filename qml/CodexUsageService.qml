pragma Singleton

// Polls codexbar-usage.sh and exposes the normalised per-provider payload to
// the bar entry and its popout. One instance for the whole shell, so N rings
// and the popout all share a single fetch.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${home}/.config`
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || `${home}/.local/share`
    readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || `${home}/.cache`

    // --- Settings, hot-reloaded from ~/.config/codexbar-caelestia/config.json ---
    property int refreshSeconds: 300
    property int ringSize: 0 // 0 means "use the bar's inner width"
    property bool showLabels: true
    property bool useProviderLogos: true
    property bool hideUnavailable: true
    property var hiddenProviders: []
    property string scriptPath: `${dataHome}/codexbar-caelestia/codexbar-usage.sh`
    property string iconDir: `${dataHome}/codexbar-caelestia/icons`

    // --- Data ---
    property var providers: []
    property bool available: false
    property bool stale: false
    property string lastError: ""
    property string updatedAt: ""
    readonly property bool loading: usageProc.running

    // Which provider the popout renders. The bar entry sets this on hover.
    property string focusedProvider: ""

    // A provider that errored *and* has no cached snapshot to fall back on has
    // never worked here — usually it is simply not set up. Showing it as a
    // permanently dashed ring is noise, so it is dropped by default. One that
    // is merely failing right now still has its cached windows and stays.
    readonly property var visibleProviders: providers.filter(p => {
        if (hiddenProviders.includes(p.id))
            return false;
        if (hideUnavailable && p.error && (p.windows?.length ?? 0) === 0)
            return false;
        return true;
    })
    readonly property var focused: visibleProviders.find(p => p.id === focusedProvider) ?? visibleProviders[0] ?? null

    // Most-constrained window across every visible provider, for consumers that
    // want a single number (an OSD, a notification threshold, ...).
    readonly property real maxPercent: {
        const vals = visibleProviders.map(p => p.maxPercent).filter(v => typeof v === "number");
        return vals.length > 0 ? Math.max(...vals) : 0;
    }

    function refresh(): void {
        if (!usageProc.running)
            usageProc.running = true;
    }

    function iconFor(id: string): string {
        return `file://${iconDir}/ProviderIcon-${id}.svg`;
    }

    Component.onCompleted: refresh()

    FileView {
        path: `${root.configHome}/codexbar-caelestia/config.json`
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: {
            try {
                const cfg = JSON.parse(text());
                if (typeof cfg.refreshSeconds === "number" && cfg.refreshSeconds > 0)
                    root.refreshSeconds = cfg.refreshSeconds;
                if (typeof cfg.ringSize === "number")
                    root.ringSize = cfg.ringSize;
                if (typeof cfg.showLabels === "boolean")
                    root.showLabels = cfg.showLabels;
                if (typeof cfg.useProviderLogos === "boolean")
                    root.useProviderLogos = cfg.useProviderLogos;
                if (typeof cfg.hideUnavailable === "boolean")
                    root.hideUnavailable = cfg.hideUnavailable;
                if (Array.isArray(cfg.hiddenProviders))
                    root.hiddenProviders = cfg.hiddenProviders;
                if (typeof cfg.scriptPath === "string" && cfg.scriptPath.length > 0)
                    root.scriptPath = cfg.scriptPath;
                if (typeof cfg.iconDir === "string" && cfg.iconDir.length > 0)
                    root.iconDir = cfg.iconDir;
            } catch (e) {
                // A malformed config must not take the widget down; the
                // built-in defaults above stay in effect.
                console.warn("codexbar-caelestia: could not parse config.json:", e);
            }
        }
    }

    Timer {
        interval: root.refreshSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    Process {
        id: usageProc

        // Deliberately sandboxed: the script only needs HOME, the XDG dirs and
        // a PATH that finds jq and the codexbar CLI. Nothing else from the
        // shell's environment is forwarded to a process that touches tokens.
        command: [
            "/usr/bin/env",
            "-i",
            `HOME=${root.home}`,
            `USER=${Quickshell.env("USER") ?? ""}`,
            `PATH=${root.home}/.local/bin:/usr/local/bin:/usr/bin:/bin`,
            `XDG_CONFIG_HOME=${root.configHome}`,
            `XDG_CACHE_HOME=${root.cacheHome}`,
            `XDG_DATA_HOME=${root.dataHome}`,
            root.scriptPath
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text.trim());
                    root.providers = parsed.providers ?? [];
                    root.available = parsed.available === true;
                    root.stale = parsed.stale === true;
                    root.lastError = parsed.error ?? "";
                    root.updatedAt = parsed.updatedAt ?? "";
                } catch (e) {
                    // Keep whatever we last rendered rather than blanking the
                    // bar, and mark it stale so the UI can say so.
                    root.stale = true;
                    root.lastError = qsTr("Could not read CodexBar usage");
                }
            }
        }
    }
}
