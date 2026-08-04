# WireGuard-Dienst konfigurieren und Nutzer verwalten

Kurzanleitung für Administratoren des `ansible-mssql`-Projekts. Betrifft
ausschließlich `roles/wireguard_server` – für die Windows-Client-Seite
siehe `wireguard-windows-anleitung.md`.

## 1. Grundkonfiguration (einmalig, in `group_vars/all/vars.yml`)

```yaml
wireguard_server_ip: 10.10.0.1      # Tunnel-IP der VM
wireguard_server_prefix: 24         # Größe des Overlay-Netzes (10.10.0.0/24)
wireguard_listen_port: 51820        # UDP-Port für den Handshake (öffentlich)
wireguard_peers: []                 # siehe Abschnitt 2
```

- **`wireguard_server_ip`** ist die Adresse, an die der SQL-Server-Port
  gebunden wird (siehe `mssql_docker/templates/docker-compose.yml.j2`) –
  eine Änderung hier erfordert einen erneuten Playbook-Lauf, damit sowohl
  `wg0` als auch der Docker-Container neu mit der passenden Adresse
  starten. Reihenfolge in `site.yml` beachten:
  `wireguard_server` **muss vor** `mssql_docker` laufen (siehe README).
- **`wireguard_listen_port`** nur ändern, wenn nötig (z. B. Port-Konflikt) –
  Clients müssen den Endpoint dann entsprechend anpassen.
- Weitere Stellschrauben: `wireguard_server_manage: false` schaltet die
  ganze Rolle ab, `wireguard_firewalld_zone` (Standard `wireguard`)
  benennt die dedizierte firewalld-Zone für das `wg0`-Interface um.

Änderungen an diesen drei Variablen ausrollen:

```bash
ansible-playbook site.yml --ask-vault-pass
```

## 2. Neuen Nutzer/Peer hinzufügen

**Schritt 1 – Client generiert sein eigenes Schlüsselpaar** (macht der
Nutzer selbst, siehe `wireguard-windows-anleitung.md` für die
Windows-GUI-Variante, oder auf Linux/Mac):

```bash
wg genkey | tee privatekey | wg pubkey > publickey
```

Der Nutzer schickt **nur den Inhalt von `publickey`** an den Admin – der
private Schlüssel bleibt immer lokal beim Nutzer.

**Schritt 2 – Freie Tunnel-IP vergeben.** Einfach hochzählen, `.1` ist die
VM selbst:

```bash
grep -oE '10\.10\.0\.[0-9]+' group_vars/all/vars.yml | sort -u
```

**Schritt 3 – Peer in `group_vars/all/vars.yml` eintragen:**

```yaml
wireguard_peers:
  - name: alice-laptop
    public_key: "AbCdEf1234567890...=="
    allowed_ip: 10.10.0.2/32
  - name: bob-homeoffice
    public_key: "GhIjKl0987654321...=="
    allowed_ip: 10.10.0.3/32
```

`public_key` ist **nicht geheim** (deshalb bewusst in `vars.yml`, nicht im
Vault). `name` ist frei wählbar, dient nur der Lesbarkeit in `wg0.conf`.
Optional: `preshared_key` pro Peer für zusätzliche Post-Quantum-Härtung
(muss dann auch clientseitig als `PresharedKey` eingetragen werden).

**Schritt 4 – Ausrollen:**

```bash
ansible-playbook site.yml --ask-vault-pass
```

Bestehende Peers und das Server-Schlüsselpaar bleiben unangetastet – es
wird nur `wg0.conf` neu geschrieben und der Dienst per Handler neu
gestartet (nur bei tatsächlicher Änderung).

**Schritt 5 – Nutzer die Server-Angaben mitteilen:**

```bash
ssh <admin>@BioDive4Soil.diversityworkbench.de \
  "sudo wg show wg0 public-key"
```

Der Nutzer braucht: Server-Public-Key (obiger Befehl, wird auch am Ende
jedes `wireguard_server`-Laufs in der Ansible-Ausgabe angezeigt), Endpoint
(`BioDive4Soil.diversityworkbench.de:51820`), und die ihm zugewiesene
`allowed_ip` als eigene `Address`.

## 3. Nutzer/Peer entfernen

Entsprechenden Eintrag aus `wireguard_peers` löschen, Playbook erneut
ausführen. Der Peer verschwindet aus `wg0.conf`, Zugriff ist sofort nach
dem automatischen `wg-quick`-Neustart gesperrt.

## 4. Prüfen, wer verbunden ist

Auf der VM:

```bash
sudo wg show wg0
```

Zeigt alle konfigurierten Peers, deren letzten Handshake und übertragene
Datenmenge. Kein Handshake seit > 3 Minuten trotz „aktivem“ Client beim
Nutzer → meist falscher Endpoint/Port oder Firewall-Problem beim Nutzer,
nicht auf Serverseite.

## 5. Typische Fehlerbilder

| Symptom | Ursache |
|---|---|
| Peer taucht nicht in `wg show` auf | Playbook seit Eintragung nicht erneut gelaufen |
| Handshake klappt nie | Public Key falsch übertragen, oder UDP `51820` extern blockiert |
| Handshake klappt, aber kein DB-Zugriff | `AllowedIPs` beim Client falsch (muss `10.10.0.1/32` enthalten); DB-Port in `wireguard`-Zone prüfen: `firewall-cmd --zone=wireguard --list-ports` |
| Neuer Peer kann sich verbinden, alte Peers nicht mehr | Kollidierende `allowed_ip` (IP doppelt vergeben) – Liste in `vars.yml` prüfen |

Ausführlichere Hintergründe (firewalld-Zonenkonzept, warum kein
`ip_forward` nötig ist, SELinux-Aspekte) stehen im Haupt-`README.md` unter
„`wireguard_server`“.
