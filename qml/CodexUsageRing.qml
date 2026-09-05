pragma ComponentBehavior: Bound

// One provider: a usage ring around the provider's logo, with the
// most-constrained window's percentage underneath.

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

Item {
    id: root

    required property var provider
    property int size: Tokens.sizes.bar.innerWidth
    property bool showLabel: true

    readonly property string providerId: provider?.id ?? ""
    readonly property bool failed: (provider?.error ?? null) !== null
    readonly property real percent: {
        const v = provider?.maxPercent;
        return typeof v === "number" ? v : 0;
    }

    // Same thresholds the dashboard card uses, so a provider reads the same
    // whichever surface you look at it on.
    readonly property color accent: failed ? Colours.palette.m3outline : percent >= 90 ? Colours.palette.m3error : percent >= 70 ? Colours.palette.m3tertiary : Colours.palette.m3primary

    implicitWidth: size
    implicitHeight: ring.implicitHeight + (label.visible ? label.implicitHeight + Tokens.spacing.extraSmall / 2 : 0)

    CircularProgress {
        id: ring

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter

        implicitSize: root.size
        strokeWidth: Math.max(2, Math.round(root.size / 11))
        spacing: Tokens.spacing.extraSmall / 2
        fgColour: root.accent
        bgColour: Colours.tPalette.m3surfaceContainerHighest
        value: root.failed ? 0 : root.percent / 100
        wavy: root.provider?.stale ?? false
        wavePaused: !CodexUsageService.loading

        Behavior on clampedVal {
            Anim {}
        }

        // Brand mark when we have the SVG, recoloured to the ring's accent so
        // it sits in the Material palette instead of fighting it.
        Loader {
            id: logo

            anchors.centerIn: parent
            // providerId is empty for the placeholder ring shown before the
            // first fetch lands; asking for ProviderIcon-.svg only logs noise.
            active: CodexUsageService.useProviderLogos && !root.failed && root.providerId !== ""
            asynchronous: true

            sourceComponent: Image {
                source: CodexUsageService.iconFor(root.providerId)
                sourceSize.width: Math.round(root.size * 0.5)
                sourceSize.height: Math.round(root.size * 0.5)
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

        // Fallback whenever the logo is off, missing or the provider errored.
        MaterialIcon {
            anchors.centerIn: parent
            visible: !logo.active || ((logo.item as Image)?.status ?? Image.Null) !== Image.Ready
            text: root.failed ? "cloud_off" : "smart_toy"
            color: root.accent
            fontStyle: Tokens.font.icon.small
            fill: 1
        }
    }

    StyledText {
        id: label

        anchors.top: ring.bottom
        anchors.topMargin: Tokens.spacing.extraSmall / 2
        anchors.horizontalCenter: parent.horizontalCenter

        visible: root.showLabel
        animate: true
        text: root.failed ? "—" : `${Math.round(root.percent)}%`
        color: root.accent
        font: Tokens.font.label.small
    }
}
