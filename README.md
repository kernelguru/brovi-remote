# Brovi Remote

iPhone-App (SwiftUI) zum Auslesen und Einstellen eines **Brovi H153-381 5G**-Routers
über dessen HiLink-Web-API.

## Funktionen

- **Login** per SCRAM (neuere Firmware) mit Rückfall auf den älteren Passwort-Login
- **Funkstatus** – LTE- und 5G-NR-Werte (RSRP, RSRQ, SINR, Band, PCI, EARFCN …),
  aktualisiert alle 3 Sekunden
- **Netz** – Netzmodus und LTE-Bandsperre; alle weiteren Felder aus `/api/net/net-mode` sind editierbar
- **API-Explorer** – beliebige GET-/POST-Anfragen an den Router, um weitere Endpunkte zu finden

## Referenz

Login, CSRF-Token-Handling und Bandmasken folgen der Python-Bibliothek
[huawei-lte-api](https://github.com/Salamek/huawei-lte-api) (Salamek).
Diese kennt allerdings keine 5G-spezifischen Endpunkte (SA/NSA, NR-Bänder).

## Build

Gebaut wird per GitHub Actions auf einem macOS-Runner (`.github/workflows/build.yml`):

1. `xcodegen generate` erzeugt das Xcode-Projekt aus `project.yml`
2. `xcodebuild` baut die App ohne Signatur
3. Die `.app` wird als `BroviRemote-unsigned.ipa` gepackt und als Artefakt hochgeladen

Bei einem Tag `v*` wird die IPA zusätzlich an ein GitHub-Release gehängt.

Die IPA ist **unsigniert** und muss vor der Installation signiert werden,
z. B. mit AltStore, SideStore, Sideloadly oder TrollStore.

## Offene Punkte

- 5G SA/NSA-Umschaltung, NR-Bänder, Frequenz-/Zellsperre: Die genauen Endpunkte des
  H153-381 sind noch nicht bestätigt. Am besten im Web-Interface des Routers die Einstellung ändern,
  in den Browser-Entwicklertools (Tab „Netzwerk“) die Anfrage mitschneiden und hier ergänzen.
