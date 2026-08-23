# Localization

The app now uses `Resources/Localizable.xcstrings`.

Languages currently included:
- English (`en`) — source language
- Português do Brasil (`pt-BR`)

To edit translations in Xcode:
1. Open `X360ControllerBridge.xcodeproj`.
2. Select `Localizable.xcstrings` in the Resources group.
3. Edit the English or Brazilian Portuguese columns.

Most visible SwiftUI strings are localized automatically. String values passed
through reusable view helpers use the `L(...)` lookup helper. Common status
strings originating in Objective-C++ also use `NSLocalizedString`.
