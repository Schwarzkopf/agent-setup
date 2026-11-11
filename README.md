# evooming agent-setup

Schnellinstallation für die evooming-Kurse **evooming Brain** und **Dein evooming agent**.
Ein Befehl richtet deinen Agent-Rechner oder deine Workstation ein, immer mit den neuesten Programmversionen und schon vorkonfiguriert.

## So startest du

**Windows 10/11:** PowerShell öffnen (kein Administrator nötig) und einfügen:

```powershell
irm https://github.com/Schwarzkopf/agent-setup/releases/latest/download/install.ps1 | iex
```

**macOS und Ubuntu/Debian:** Terminal öffnen und einfügen:

```bash
curl -fsSL https://github.com/Schwarzkopf/agent-setup/releases/latest/download/install.sh | bash
```

Das Skript fragt zuerst, welchen Rechner du einrichtest, dann nach zwei Passwörtern. Danach läuft es von selbst durch. Am Ende siehst du, was geklappt hat, und eine Liste der Schritte, die du noch von Hand machst.

Du kannst es jederzeit noch einmal starten: Installiertes wird aktualisiert, Erledigtes übersprungen. Das ist auch der einfachste Weg, alles auf den neuesten Stand zu bringen.

## Was eingerichtet wird

| | Agent-Rechner | Workstation |
|:---|:---|:---|
| Syncthing | als Dienst, startet automatisch, Oberfläche mit Passwort geschützt | ebenso |
| Vault-Ordner | `evooming-Brain` wird angelegt, Ignoriermuster für Obsidian gesetzt | Rechte und Ignoriermuster, sobald du die ZIP entpackt hast |
| RustDesk | evooming-Server eingetragen, dauerhaftes Passwort, nur dieses Passwort gilt | evooming-Server eingetragen |
| Energie | kein Standby, Neustart nach Stromausfall (macOS), unter Ubuntu auf Wunsch automatische Anmeldung und Xorg | – |
| Google Chrome | ja | – |
| ChatGPT Desktop | ja | – |
| Obsidian | – | ja |
| Hermes (evooming agent) | offizieller Installer mit Einrichtungsassistent | – |

Woher die Programme kommen: Windows über winget und die offiziellen GitHub-Releases, macOS über Homebrew, Ubuntu über die offiziellen Paketquellen und .deb-Pakete der Hersteller.

## Was du weiterhin selbst machst

Manches lässt sich nicht sicher automatisieren, weil es um deine Konten oder um Rechte geht, die nur du erteilen darfst:

- Vault-ZIP aus dem Kurs entpacken (Lektion 2.1)
- Bei ChatGPT anmelden, Telegram-Bot anlegen und Hermes damit verbinden (Lektionen 2.6, 3.4, 3.5)
- Syncthing: beide Rechner koppeln und den Vault-Ordner teilen (Lektion 3.2). Die Geräte-ID zeigt dir das Skript am Ende an.
- macOS: RustDesk die Rechte „Bildschirmaufnahme“ und „Bedienungshilfen“ geben. Das Skript öffnet dir die richtigen Seiten.
- Windows und macOS: automatische Anmeldung einschalten (Lektion 3.1)

## Optionen

| macOS/Linux | Windows | Wirkung |
|:---|:---|:---|
| `--role agent` / `--role workstation` | `EVOOMING_ROLE` | Rolle ohne Rückfrage |
| `--yes` | `EVOOMING_YES=1` | keine Rückfragen, Vorschläge übernehmen |
| `--skip-hermes` | `EVOOMING_SKIP_HERMES=1` | Hermes nicht installieren |
| `--dry-run` | `EVOOMING_DRY_RUN=1` | nur anzeigen, nichts verändern |

Beispiel macOS/Linux: `curl -fsSL …/install.sh | bash -s -- --role workstation`

Beispiel Windows: `$env:EVOOMING_ROLE='workstation'; irm …/install.ps1 | iex`

Passwörter ohne Rückfrage: `EVOOMING_SYNCTHING_PASSWORD`, `EVOOMING_SYNCTHING_USER`, `EVOOMING_RUSTDESK_PASSWORD`.

Ein Protokoll liegt nach jedem Lauf in deinem Benutzerordner: `evooming-setup.log` (Windows zusätzlich `evooming-setup-admin.log`). Passwörter stehen nicht darin.

## Sicherheit

- Das Skript ist offen einsehbar. Lies es gern, bevor du es startest: [install.sh](install.sh), [install.ps1](install.ps1), [setup.ps1](setup.ps1).
- Es lädt nur von den offiziellen Quellen der Hersteller.
- Im Repo stehen keine Passwörter. Der RustDesk-Schlüssel im Skript ist der öffentliche Schlüssel des evooming-Servers, den jeder RustDesk-Client bekommt.
- Unter Windows werden die Passwörter zwischen den beiden Fenstern verschlüsselt übergeben (nur dein Benutzerkonto kann sie lesen) und danach gelöscht.

---

## Für die Pflege

### Aufbau

- `install.sh`: macOS und Ubuntu/Debian, ein einziges Skript.
- `install.ps1`: kleiner Lader für Windows, nur ASCII. Er lädt `setup.ps1`, speichert es als Datei und startet es. So bleiben die Umlaute in Windows PowerShell 5.1 heil, und `setup.ps1` kann Administratorrechte anfordern.
- `setup.ps1`: eigentliches Windows-Skript, UTF-8 **mit BOM** (sonst zeigt PowerShell 5.1 die Umlaute falsch an).

### Testen

`.github/workflows/test.yml` läuft bei jedem Push, jeden Montag früh und vor jedem Release:

- shellcheck und PSScriptAnalyzer
- Ubuntu: echte Installation als Agent-Rechner, zweiter Lauf, Prüfung der Dienste und Einstellungen, dann Workstation
- Hermes-Installer ohne Assistent
- macOS: Probelauf Agent-Rechner, echte Installation Workstation
- Windows: Probelauf beider Rollen, Aufruf über `irm | iex`, echte Installation von Syncthing und RustDesk

Schlägt der Montagslauf fehl, hat meist ein Hersteller einen Download oder Paketnamen geändert.

Lokal testen:

```bash
bash install.sh --dry-run --role agent
```

### Neues Release

```bash
git tag v1.0.1
git push origin v1.0.1
```

Der Release-Workflow lässt alle Tests laufen, trägt die Versionsnummer in die Skripte ein und veröffentlicht `install.sh`, `install.ps1` und `setup.ps1` als Release. Der Link im Kurs (`releases/latest/download/…`) zeigt danach automatisch auf die neue Version. Geht etwas schief, das vorige Release auf GitHub wieder als „Latest“ markieren.

Änderungen auf `main` erreichen die Teilnehmenden erst mit dem nächsten Release.
