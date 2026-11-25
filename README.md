# Trilium Mobile

Mobiler Client für [Trilium Notes](https://github.com/TriliumNext/Trilium) (Android und iOS, Flutter).

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

Jeder Push auf `main` startet [`.github/workflows/build.yml`](.github/workflows/build.yml):
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
