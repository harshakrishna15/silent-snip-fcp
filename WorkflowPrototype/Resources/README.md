# Workflow icon

`ExtensionIcon` is a transparent split-waveform silhouette. Final Cut's toolbar
tints its alpha, so an opaque colored badge would become a solid square.
`SilentSnipIcon.svg` is its editable vector drawing. The separate `WorkflowBadge`
assets and `WorkflowBadge.svg` retain the mint badge for the window header and
containing app. `Scripts/render-workflow-icon.m` renders both geometries offscreen
with AppKit and creates their macOS icon representations.

Apple's installed Workflow Extensions SDK template declares
`CFBundleIconFile = ExtensionIcon` in `TemplateInfo.plist` and provides 32 × 32
and 64 × 64 artwork in its `AppIcon.appiconset`. The extension uses that public
bundle-icon contract. This does not replace Final Cut's own generic Extensions
button when the host chooses to display one.

To regenerate the checked-in icon resources from the repository root:

```sh
xcrun clang -fobjc-arc -framework AppKit Scripts/render-workflow-icon.m -o /tmp/silentsnip-icon
/tmp/silentsnip-icon WorkflowPrototype/Resources
```

The generator opens no windows, reads no projects or media, and removes its
temporary iconsets. The containing app receives `WorkflowBadge.icns` as
`AppIcon.icns`; the extension's public bundle-icon declaration uses the
transparent `ExtensionIcon.icns`. The header loads `WorkflowBadge.png`.
