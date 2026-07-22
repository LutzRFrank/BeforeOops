# BeforeOops

Eine lokale SwiftUI-App für iPhone und Mac: Dokument erfassen, verständlich zusammenfassen, belegte Fristen und Handlungen prüfen und nach Bestätigung eine Erinnerung erstellen – bevor etwas übersehen wird.

## Aktueller Stand

- gemeinsames iOS-/macOS-App-Target
- PDF- und Bildimport
- mehrseitiger Dokumentenscan auf iPhone
- lokale, geschützte Ablage der Originale
- SwiftData-Dokumentliste
- Quick-Look-Originalansicht
- lokale OCR für PDF- und Bilddateien (Deutsch/Englisch)
- automatisch gespeicherter, auswählbarer Volltext

## Voraussetzungen

- Xcode 27 oder neuer
- iOS 26 / macOS 26

## Datenschutz

BeforeOops verarbeitet Dokumente lokal und synchronisiert sie, sofern verfügbar, über den privaten CloudKit-Bereich des persönlichen Apple-Accounts. Weitere Einzelheiten stehen in [PRIVACY.md](PRIVACY.md).

## Support

Bei Fragen oder Problemen erreichst du den BeforeOops-Support unter [mac@applem1.de](mailto:mac@applem1.de). Fehler und Funktionswünsche können außerdem über [GitHub Issues](https://github.com/LutzRFrank/BeforeOops/issues) gemeldet werden.

## Build

```sh
xcodebuild -project Posteingang.xcodeproj -scheme Posteingang -destination 'platform=macOS' build
```
