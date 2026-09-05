pragma ComponentBehavior: Bound

// Bar entry: a pill holding one usage ring per enabled CodexBar provider.
// Registered in Bar.qml under the "codexUsage" entry id.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.services

StyledRect {
    id: root

    readonly property alias items: ringColumn
    readonly property int ringSize: CodexUsageService.ringSize > 0 ? CodexUsageService.ringSize : Tokens.sizes.bar.innerWidth

    // Bar.qml calls this with a y in this item's coordinates. Returns the ring
    // under the pointer (so the bar can centre the popout on it) and points the
    // shared service at that provider, keeping Bar.qml free of any import of
    // ours beyond the CodexUsage type itself.
    function hoverAt(y: real): Item {
        const ring = ringColumn.childAt(ringColumn.width / 2, mapToItem(ringColumn, 0, y).y);
        if (ring?.providerId)
            CodexUsageService.focusedProvider = ring.providerId;
        return ring ?? null;
    }

    color: Colours.tPalette.m3surfaceContainer
    radius: Tokens.rounding.full

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: ringColumn.implicitHeight + Tokens.padding.medium * 2

    ColumnLayout {
        id: ringColumn

        anchors.centerIn: parent
        spacing: Tokens.spacing.small

        Repeater {
            model: ScriptModel {
                values: CodexUsageService.visibleProviders
            }

            CodexUsageRing {
                required property var modelData

                Layout.alignment: Qt.AlignHCenter

                provider: modelData
                size: root.ringSize
                showLabel: CodexUsageService.showLabels
            }
        }

        // Keeps the entry (and therefore its hover target) alive before the
        // first fetch lands, and whenever every provider is filtered out.
        CodexUsageRing {
            Layout.alignment: Qt.AlignHCenter

            visible: CodexUsageService.visibleProviders.length === 0
            provider: ({
                    id: "",
                    error: CodexUsageService.loading ? null : (CodexUsageService.lastError || "No provider data"),
                    maxPercent: 0
                })
            size: root.ringSize
            showLabel: CodexUsageService.showLabels
        }
    }
}
