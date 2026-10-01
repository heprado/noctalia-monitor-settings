pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One-shot command runner: run(argv, callback) spawns a process and calls
// callback({ exitCode, stdout, stderr }) once it's done. Every ddcutil and
// wlr-randr call in the app goes through here -- argv arrays only, never a
// shell string.
Singleton {
    id: root

    // A binary that isn't installed never emits `exited`, only a
    // `runningChanged` back to false -- reported as exit code 127, the
    // shell's own "command not found".
    readonly property int notFound: 127

    function run(command, callback) {
        const proc = processComponent.createObject(root, { command: command, callback: callback || null })
        proc.running = true
        return proc
    }

    Component {
        id: processComponent

        Process {
            id: proc
            property var callback: null
            property bool finished: false

            stdout: StdioCollector { id: out }
            stderr: StdioCollector { id: err }

            function finish(code) {
                if (finished) return
                finished = true
                if (callback) {
                    try {
                        callback({ exitCode: code, stdout: out.text, stderr: err.text })
                    } catch (e) {
                        console.error("Exec callback failed for", command, e)
                    }
                }
                proc.destroy()
            }

            // Stdio collectors are flushed before `exited` fires, so the
            // text is complete here; `exited` also always precedes the
            // runningChanged that follows it, so the second handler only
            // ever fires on its own for a process that never started.
            onExited: (exitCode, exitStatus) => finish(exitCode)
            onRunningChanged: if (!running && !finished) finish(root.notFound)
        }
    }
}
