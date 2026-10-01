pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Translations: the same translations/<lang>.json files the Noctalia side
// of the plugin uses (one source for both), picked from the system
// locale, falling back to English key by key.
Singleton {
    id: root

    readonly property string dir: Quickshell.shellDir + "/../translations"
    readonly property var available: ["en", "pt-BR", "es", "de", "ja", "ru", "zh-Hans"]

    // "pt_BR" -> "pt-BR"; otherwise the bare language ("ja_JP" -> "ja");
    // Chinese maps to the simplified file, the only one there is.
    readonly property string language: {
        const name = Qt.locale().name
        const dashed = name.replace("_", "-")
        if (available.indexOf(dashed) !== -1) return dashed
        const lang = name.split("_")[0]
        if (lang === "zh") return "zh-Hans"
        if (available.indexOf(lang) !== -1) return lang
        return "en"
    }

    property var strings: ({})
    property var fallback: ({})

    function parse(file) {
        try {
            return JSON.parse(file.text())
        } catch (e) {
            return {}
        }
    }

    // Loaded before any window exists (see blockLoading's docs), so the
    // first frame is already translated.
    FileView {
        id: current
        path: root.dir + "/" + root.language + ".json"
        blockLoading: true
        onLoaded: root.strings = root.parse(current)
    }

    FileView {
        id: english
        path: root.dir + "/en.json"
        blockLoading: true
        onLoaded: root.fallback = root.parse(english)
    }

    Component.onCompleted: {
        strings = parse(current)
        fallback = parse(english)
    }

    function lookup(table, key) {
        let node = table
        const parts = key.split(".")
        for (let i = 0; i < parts.length; i++) {
            if (node === null || typeof node !== "object") return undefined
            node = node[parts[i]]
        }
        return typeof node === "string" ? node : undefined
    }

    // tr("display.confirm", { seconds: 15 }) -> "... {seconds} ..." filled in.
    // An untranslated key returns null, so callers can fall back to
    // ddcutil's raw English text with `I18n.tr(key) ?? raw`.
    function tr(key, vars) {
        let s = lookup(strings, key)
        if (s === undefined) s = lookup(fallback, key)
        if (s === undefined) return null
        if (vars) {
            for (const k in vars) s = s.split("{" + k + "}").join(String(vars[k]))
        }
        return s
    }

    // tr() for UI text that must never be blank: the key itself as a last
    // resort, so a missing string is visible rather than an empty label.
    function t(key, vars) {
        const s = tr(key, vars)
        return s === null ? key : s
    }
}
