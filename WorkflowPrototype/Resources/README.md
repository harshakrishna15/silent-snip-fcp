# Workflow icons

The extension uses a transparent waveform icon; the app and window header use the mint badge.

| Resource | Use |
| --- | --- |
| `SilentSnipIcon.svg` | Editable waveform artwork |
| `ExtensionIcon.icns` | Transparent extension icon |
| `WorkflowBadge.svg` | Editable mint badge artwork |
| `WorkflowBadge.icns` | Containing app icon, copied as `AppIcon.icns` |
| `WorkflowBadge.png` | Window header badge |

Final Cut tints the extension icon's alpha, so keep its background transparent. An opaque badge would appear as a solid square. The extension declares `CFBundleIconFile = ExtensionIcon`; Final Cut may still show its own generic Extensions toolbar button.

To regenerate the resources from the repository root:

```sh
xcrun clang -fobjc-arc -framework AppKit Scripts/render-workflow-icon.m -o /tmp/silentsnip-icon
/tmp/silentsnip-icon WorkflowPrototype/Resources
```

The generator uses AppKit offscreen, opens no windows, and removes its temporary iconsets.
