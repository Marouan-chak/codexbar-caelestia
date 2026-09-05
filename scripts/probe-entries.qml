// Prints Caelestia's effective bar entry order and status icon list, so
// install.sh's built-in default can be re-derived after a Caelestia upgrade:
//
//   qs -p scripts/probe-entries.qml
//
// Runs standalone — it does not load the Caelestia shell, so it will not fight
// a running instance over the notification bus.

import QtQuick
import Quickshell
import Caelestia.Config

ShellRoot {
    Component.onCompleted: {
        console.log("entries=" + JSON.stringify(Config.bar.entries.values.map(x => ({
                        id: x.id,
                        enabled: x.enabled
                    }))));
        console.log("statusIcons=" + JSON.stringify(Config.bar.statusIcons.values.map(x => ({
                        id: x.id,
                        enabled: x.enabled
                    }))));
        Qt.callLater(() => Qt.exit(0));
    }
}
