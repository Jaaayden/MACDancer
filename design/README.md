# App icon

`AppIcon.swift` draws the icon with Core Graphics: six capsules (the six
bytes of a MAC address) leaning to a beat on a blue-violet squircle, with the
"changed" byte in mint. It follows the macOS icon grid (824 pt body on a
1024 pt canvas, transparent outside).

Regenerate every size:

```sh
swiftc -O design/AppIcon.swift -o /tmp/macdancer-icon && /tmp/macdancer-icon /tmp/icon-1024.png
for n in 16 32 64 128 256 512 1024; do
  sips -z $n $n /tmp/icon-1024.png --out Sources/App/Assets.xcassets/AppIcon.appiconset/MACDancer-AppIcon-$n.png
done
```
