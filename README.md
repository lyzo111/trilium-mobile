# Trilium Mobile

Dieses Repo liefert zwei Apps für [Trilium Notes](https://github.com/TriliumNext/Trilium):

| | Offizielle App (empfohlen) | Eigene Flutter-App |
| --- | --- | --- |
| Release | `TriliumNotes-mobile-<tag>.apk` (Tag `trilium-v…`) | `TriliumMobile-<version>.apk` |
| Offline | **alles lesen und bearbeiten** | nur lesen |
| Sync | Triliums eigener Sync (beide Richtungen, wie Desktop) | Kopie vom Server per ETAPI |
| Updates | täglicher Check auf neue Trilium-Releases, baut automatisch | Server-UI immer aktuell |
| App-ID | `org.triliumnotes.trilium` | `de.chris.trilium` |

## Offizielle App

[`.github/workflows/official.yml`](.github/workflows/official.yml) baut Triliums eigene Mobil-App
(`apps/mobile` im Trilium-Repo, Capacitor). Sie enthält die komplette Trilium-Oberfläche **und**
den Trilium-Kern samt SQLite-Datenbank (als WebAssembly) – das Handy ist damit eine vollwertige
Trilium-Instanz, die mit deinem Server synchronisiert. Einrichtung in der App:
„Mit bestehendem Server verbinden“ → Server-Adresse und Passwort.

- Jeden Morgen prüft der Workflow das neueste stabile Trilium-Release und baut es einmal.
  Kein Code hier muss sich dafür ändern.
- **Server und App müssen dieselbe Trilium-Version haben**, sonst verweigert der Sync die
  Verbindung. Also Server aktualisieren und die neue APK installieren.
- Eine bestimmte Version baust du per „Run workflow“ mit Tag (z. B. `v0.107.0`).
- Die App ist bei Trilium noch nicht offiziell veröffentlicht (nur als Nightly) – also
  experimentell. iOS baut dieser Workflow nicht.

Getestet mit Trilium 0.107.0 im Emulator: Ersteinrichtung mit Server-Sync, Offline-Bearbeitung
nach Kaltstart ohne Server, Änderung kam nach ~30 s auf dem Server an, eine auf dem Server
angelegte Notiz nach ~1 Min. in der App.

## Eigene Flutter-App

Mobiler Client (Android und iOS, Flutter): online die Server-Oberfläche, offline eine
Lese-Kopie.

## Wie die App immer auf dem neuesten Stand bleibt

Die App baut die Trilium-Oberfläche **nicht** nach. Online zeigt sie die Web-Oberfläche deines
eigenen Servers in einer WebView (Trilium liefert Mobilgeräten automatisch die Mobil-Ansicht).
Jede neue Funktion, die nach einem Server-Update dazukommt, ist deshalb sofort in der App da,
ohne dass sich hier am Code etwas ändern muss.

Neben der Oberfläche spricht die App nur mit der stabilen, versionierten
[ETAPI](https://github.com/TriliumNext/Trilium/blob/main/apps/server/src/assets/etapi.openapi.yaml) des Servers:

| Zweck | Endpunkte |
| --- | --- |
| Anmelden (Passwort → Token) | `POST /etapi/auth/login`, `POST /etapi/auth/logout` |
| Erreichbarkeit | `GET /etapi/app-info` |
| Offline-Kopie | `GET /etapi/notes?search=…` (alle Metadaten in einer Anfrage), `GET /etapi/notes/{id}/content`, `GET /etapi/attachments/{id}/content` |

## Synchronisation und Offline-Modus

- Beim Start, beim Zurückkehren in die App (wenn älter als 15 Min.), alle 30 Min. und per Knopf
  wird der Notizbaum auf das Gerät gespiegelt.
- Inhalte werden nur neu geladen, wenn sich ihre `blobId` geändert hat; ein zweiter Sync
  dauert daher nur Sekundenbruchteile. Gelöschte Notizen verschwinden auch lokal.
- Gespiegelt werden Text-, Code-, Mermaid- und Bildnotizen samt eingebetteter Bilder. Geschützte
  Notizen, Dateien, Canvas, Mindmaps usw. gibt es nur online.
- Ist der Server nicht erreichbar, zeigt die App automatisch die Offline-Kopie: Notizbaum,
  Volltextsuche, interne Links funktionieren. Die Offline-Kopie ist **nur lesbar** – geschrieben
  wird immer direkt auf dem Server, dadurch kann es keine Konflikte geben.
- Kommt der Server zurück, bietet die App an, wieder online zu gehen.

## Anmeldung

Bei der Einrichtung gibst du Server-Adresse und Trilium-Passwort ein. Die App holt sich damit
ein ETAPI-Token (sichtbar unter *Optionen → ETAPI*) und meldet die Web-Oberfläche an. Mit
„Automatisch anmelden“ wird das Passwort im Keystore/Keychain verschlüsselt gespeichert, damit
die App eine abgelaufene Web-Sitzung selbst erneuern kann. Alternativ geht auch ein
vorhandenes ETAPI-Token (dann meldest du dich in der Web-Oberfläche einmal selbst an).

## Releases

Jeder Push auf `main`, der die Flutter-App ändert, startet [`.github/workflows/build.yml`](.github/workflows/build.yml):
Analyse, Tests, signiertes Release-APK, GitHub-Release `TriliumMobile-<version>.apk`.
Ein unsigniertes iOS-`.ipa` (zum Sideloaden) baut der Workflow bei manuellem Start mit
Haken bei „ios“.

Die Versionsnummer steht in `pubspec.yaml` (`version:`). Signiert wird mit dem Keystore aus
dem Repo-Secret `DEBUG_KEYSTORE` (base64), damit jedes APK als Update über das vorige passt.

## Entwicklung

```sh
flutter test                                   # Unit- und Sync-Tests mit Fake-Server
TRILIUM_URL=http://127.0.0.1:8089 TRILIUM_PASSWORD=… \
  flutter test test/live_server_test.dart      # gegen einen echten Server
flutter build apk --release
```

`lib/` im Überblick: `etapi.dart` (API-Client), `sync.dart` (Spiegelung), `store.dart`
(Offline-Speicher), `render.dart` (HTML für die Offline-Ansicht), `screens/` (Oberfläche).
