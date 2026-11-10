# App icon

`App/AppIcon.icon` is the Icon Composer app icon (macOS 26+): two layers, the padlock and the original's soft drop
shadow (system group shadow off), over an off-white background in
light appearance and navy in dark. The system derives the Clear and Tinted variants. `App/Assets.xcassets/AppMark.imageset`
and `AppMarkShadow.imageset` are the same two layers for the UI (`AppIconTile`), over the `lp.iconTile` colour (the same two backgrounds, `gen_colors.py`).

Both layers are keyed out of the 1.x icon (`build/appicon.png`, navy background):

    swiftc -O -o key-app-mark native/Tools/ui/icon/key-app-mark.swift
    ./key-app-mark build/appicon.png lock.png 16 3 shadow.png   # threshold 16 (red channel), open radius 3

Then copy `lock.png` and `shadow.png` to `App/AppIcon.icon/Assets/`, and to `AppMark.imageset/app-mark@2x.png` and
`AppMarkShadow.imageset/app-mark-shadow@2x.png` (plus 512 px copies without `@2x`). Check every rendition before committing:

    ictool=/Applications/Xcode.app/Contents/Applications/Icon\ Composer.app/Contents/Executables/ictool
    for r in Default Dark ClearLight ClearDark TintedLight TintedDark; do
      "$ictool" native/App/AppIcon.icon --export-image --output-file $r.png --platform macOS --rendition $r --width 256 --height 256 --scale 1
    done
