# Brovi Remote

iPhone-App (SwiftUI) zum Auslesen und Einstellen eines **Brovi H153-381 5G**-Routers
über dessen HiLink-Web-API.

## Funktionen

- **Login** per SCRAM mit Rückfall auf den älteren Passwort-Login, gespeichert per Face ID
- **Funk** – LTE- und 5G-NR-Werte (RSRP, RSRQ, SINR, Band, PCI …), Zell-ID/eNB,
  gebündelte Zellen (Carrier Aggregation) und Nachbarzellen
- **Netz** – 5G SA / NSA / SA+NSA, nur 4G (FDD/TDD), Netzmodus und LTE-Bandmaske
- **Sperre** – Band-, Frequenz- und Zellsperre (PCI) für 4G und 5G (`/api/net/lock-freq`)
- **Gerät** – mobile Daten, Roaming, VoLTE, Netz neu verbinden, Datenverbrauch,
  LED-Nachtmodus, geplanter Neustart, Neustart, Netzbetreiberwahl, APN-Profile,
  Ping/Traceroute, verbundene Geräte, API-Explorer
- **SMS** – lesen, senden, löschen

## Herkunft der Schnittstellen

- Login, Token-Handling und Bandmasken: Python-Bibliothek
  [huawei-lte-api](https://github.com/Salamek/huawei-lte-api) (Salamek)
- 5G-Modus, Sperren, Entwickleranmeldung (`loginflag=2`) und die verschlüsselten Anfragen
  (Curve25519 + AES-GCM, `enc-type`): nachgebaut aus der Weboberfläche des Routers
  (`js/networkmode.js`, `js/lockband.js`, `js/main.js`)

## Build

Gebaut wird per GitHub Actions auf einem macOS-Runner (`.github/workflows/build.yml`):

1. `xcodegen generate` erzeugt das Xcode-Projekt aus `project.yml`
2. `xcodebuild` baut die App ohne Signatur
3. Die `.app` wird als `BroviRemote-unsigned.ipa` gepackt und als Artefakt hochgeladen

Bei einem Tag `v*` wird die IPA zusätzlich an ein GitHub-Release gehängt.

Die IPA ist **unsigniert** und muss vor der Installation signiert werden,
z. B. mit AltStore, SideStore, Sideloadly oder TrollStore.

## Nicht unterstützt

- USSD ist in der Firmware des H153-381 abgeschaltet (`ussd_enabled = 0`)
- Verschlüsselung nur per ECC; Router, die nur RSA anbieten, können keine SMS senden
