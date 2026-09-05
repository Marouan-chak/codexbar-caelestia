pragma ComponentBehavior: Bound

// Bar popout for the hovered provider: every usage window it reports, with a
// live reset countdown, plus pace and credit lines when the CLI supplies them.
// Installed as modules/bar/popouts/CodexUsage.qml, registered as "codexusage".

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.bar.components

Item {
    id: root

    readonly property var provider: CodexUsageService.focused
    readonly property bool failed: (provider?.error ?? null) !== null
    readonly property real percent: {
        const v = provider?.maxPercent;
        return typeof v === "number" ? v : 0;
    }
    readonly property color accent: failed ? Colours.palette.m3outline : percent >= 90 ? Colours.palette.m3error : percent >= 70 ? Colours.palette.m3tertiary : Colours.palette.m3primary

    // Turns a reset timestamp into "Resets in 51 min". Falls back to the
    // provider's own wording, which for some providers is a whole sentence and
    // is therefore shown unprefixed.
    function resetText(w: var): string {
        if (w?.resetsAt) {
            const ms = new Date(w.resetsAt).getTime() - Time.date.getTime();
            if (!isNaN(ms) && ms > 0) {
                const mins = Math.round(ms / 60000);
                if (mins < 60)
                    return qsTr("Resets in %1 min").arg(Math.max(1, mins));
                const hours = Math.round(mins / 60);
                if (hours < 24)
                    return qsTr("Resets in %1 h").arg(hours);
                return qsTr("Resets in %1 d").arg(Math.round(hours / 24));
            }
        }
        const desc = w?.resetDescription ?? "";
        if (!desc)
            return "";
        return desc.length > 24 ? desc : qsTr("Resets %1").arg(desc);
    }

    // A definite width has to come from outside the layout: a ColumnLayout
    // recomputes its own implicitWidth from its children, so assigning it
    // here would be overwritten and one long unwrapped line — a provider
    // error — would stretch the popout across the screen. This Item pins
    // the width and the layout inherits it, so children wrap and elide.
    // There is no popout width token; the network popout's is the closest.
    implicitWidth: Tokens.sizes.bar.networkWidth
    implicitHeight: layout.implicitHeight

    ColumnLayout {
        id: layout

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top

        spacing: Tokens.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            Loader {
                id: logo

                Layout.alignment: Qt.AlignVCenter
                active: CodexUsageService.useProviderLogos && !root.failed && (root.provider?.id ?? "") !== ""
                asynchronous: true

                sourceComponent: Image {
                    source: CodexUsageService.iconFor(root.provider.id)
                    sourceSize.width: Tokens.font.icon.medium.pointSize * 1.6
                    sourceSize.height: Tokens.font.icon.medium.pointSize * 1.6
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    asynchronous: true
                    visible: status === Image.Ready

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        colorization: 1
                        colorizationColor: root.accent
                        brightness: 1
                    }
                }
            }

            MaterialIcon {
                Layout.alignment: Qt.AlignVCenter
                visible: !logo.active || ((logo.item as Image)?.status ?? Image.Null) !== Image.Ready
                text: root.failed ? "cloud_off" : "smart_toy"
                color: root.accent
                fontStyle: Tokens.font.icon.medium
                fill: 1
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: root.provider ? qsTr("%1 Usage").arg(root.provider.name) : qsTr("CodexBar")
                    font: Tokens.font.title.small
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        if (!root.provider)
                            return CodexUsageService.lastError || qsTr("Waiting for usage data");
                        if (root.failed)
                            return root.provider.error;
                        const plan = root.provider.plan ? root.provider.plan.charAt(0).toUpperCase() + root.provider.plan.slice(1) : qsTr("Account");
                        return root.provider.stale ? qsTr("%1 · cached").arg(plan) : qsTr("%1 · live").arg(plan);
                    }
                    color: root.provider?.stale ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                    wrapMode: Text.Wrap
                    maximumLineCount: root.failed ? 4 : 1
                    elide: Text.ElideRight
                }
            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                icon: "refresh"
                type: IconButton.Tonal
                disabled: CodexUsageService.loading
                onClicked: CodexUsageService.refresh()
            }
        }

        Repeater {
            model: root.provider?.windows ?? []

            ColumnLayout {
                id: window

                required property var modelData

                Layout.fillWidth: true
                Layout.topMargin: Tokens.spacing.extraSmall
                spacing: Tokens.spacing.extraSmall / 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    StyledText {
                        Layout.fillWidth: true
                        text: window.modelData.label
                        font: Tokens.font.body.medium
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: root.resetText(window.modelData)
                        visible: text.length > 0
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                        elide: Text.ElideRight
                    }
                }

                StyledProgressBar {
                    Layout.fillWidth: true
                    implicitHeight: Tokens.padding.small
                    value: (window.modelData.usedPercent ?? 0) / 100
                    fgColour: (window.modelData.usedPercent ?? 0) >= 90 ? Colours.palette.m3error : (window.modelData.usedPercent ?? 0) >= 70 ? Colours.palette.m3tertiary : Colours.palette.m3primary
                }

                StyledText {
                    text: qsTr("%1% Used").arg(Math.round(window.modelData.usedPercent ?? 0))
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.small
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.extraSmall
            visible: text.length > 0
            text: root.provider?.pace ?? ""
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: {
                const parts = [];
                if (typeof root.provider?.credits === "number")
                    parts.push(qsTr("Credits: %1").arg(root.provider.credits));
                if (typeof root.provider?.resetCredits === "number")
                    parts.push(qsTr("Reset credits: %1").arg(root.provider.resetCredits));
                return parts.join(" · ");
            }
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.small
            elide: Text.ElideRight
        }

        StyledText {
            Layout.fillWidth: true
            visible: (root.provider?.windows?.length ?? 0) === 0
            text: root.failed ? qsTr("No usage to show") : CodexUsageService.loading ? qsTr("Fetching usage…") : qsTr("No usage windows reported")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            wrapMode: Text.Wrap
        }
    }
}
