# WireGuard unter Windows einrichten – Zugang zu BioDive4Soil

Kurzanleitung für die Verbindung zum Server `BioDive4Soil.diversityworkbench.de`
und den darüber erreichbaren MSSQL-Server.

## 1. WireGuard installieren

1. [https://www.wireguard.com/install/](https://www.wireguard.com/install/)
   öffnen und den Windows-Installer herunterladen.
2. Installer ausführen, Standardeinstellungen übernehmen.
3. WireGuard-App über das Startmenü öffnen.

## 2. Eigenen Schlüssel erzeugen

1. In der WireGuard-App: **Tunnel hinzufügen** → **Leeren Tunnel
   hinzufügen…** wählen.
2. WireGuard erzeugt automatisch ein Schlüsselpaar. Der **Public Key**
   steht oben im Editor.
3. Diesen Public Key kopieren und dem Administrator zuschicken. Im
   Gegenzug bekommt ihr von dort:
   - eure zugewiesene **Tunnel-IP** (z. B. `10.10.0.2/32`)
   - den **Server-Public-Key**
   - ggf. abweichende Port-/Endpoint-Angaben

Der **Private Key** bleibt immer nur lokal in der App – der wird nirgends
hin verschickt.

## 3. Konfiguration eintragen

Im Tunnel-Editor bleiben Name und Private Key wie vorausgefüllt stehen.
Den Rest so ergänzen (Platzhalter durch die vom Admin erhaltenen Werte
ersetzen):

```ini
[Interface]
PrivateKey = <bereits automatisch eingetragen>
Address = 10.10.0.2/32

[Peer]
PublicKey = <Server-Public-Key vom Admin>
Endpoint = BioDive4Soil.diversityworkbench.de:51820
AllowedIPs = 10.10.0.1/32
PersistentKeepalive = 25
```

- **Address**: eure zugewiesene Tunnel-IP.
- **AllowedIPs**: nur die Server-Tunnel-IP (`10.10.0.1/32`) – es wird nur
  der Datenbankzugriff getunnelt, nicht der gesamte Internetverkehr.
- **PersistentKeepalive = 25**: hält die Verbindung durch Router/Firewalls
  hindurch stabil.

Mit **Speichern** den Tunnel anlegen.

## 4. Verbindung aufbauen

Tunnel in der Liste auswählen und auf **Aktivieren** klicken. Der Status
wechselt auf **Aktiv**, sobald der Handshake mit dem Server erfolgreich
war (das geht normalerweise innerhalb weniger Sekunden).

## 5. Mit dem SQL Server verbinden

In SSMS, Azure Data Studio oder der jeweiligen Anwendung als Servername
eintragen:

```
10.10.0.1,1433
```

(Server-Tunnel-IP und Port, durch Komma getrennt) und mit den vom Admin
bereitgestellten Datenbank-Zugangsdaten anmelden.

## Bei Problemen

| Symptom | Mögliche Ursache |
|---|---|
| Tunnel wird nicht "Aktiv" | Public Key falsch übertragen/vertippt – mit Admin abgleichen |
| Tunnel "Aktiv", aber keine DB-Verbindung | Eigene Firewall/Virenscanner blockiert UDP; Endpoint/Port prüfen |
| Verbindung bricht nach kurzer Zeit ab | `PersistentKeepalive` fehlt oder falsch gesetzt |

Bei anhaltenden Problemen: Admin mit dem eigenen Public Key und einer
kurzen Fehlerbeschreibung kontaktieren.
