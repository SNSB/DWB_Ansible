# Ansible: MSSQL-Server (Docker + Agent + Backups) deployen

Deployt den zuvor gebauten MSSQL-Docker-Stack (Dockerfile, Compose-Datei,
SQL-Server-Agent-Backup-Job, sa-Sperrung) automatisiert auf eine VM. Räumt
nach dem Build nicht mehr benötigte Docker-Images auf, richtet einen
chroot-beschränkten SFTP-only-Nutzer mit Lesezugriff auf die Backup-Dateien
ein - und sichert den Netzwerkzugriff zweigleisig ab:

- **SQL Server**: nur über WireGuard erreichbar. Der DB-Port ist nicht mal
  an `0.0.0.0` gebunden, sondern ausschließlich an die WireGuard-Tunnel-IP
  der VM - ohne gültigen Peer-Schlüssel kommt niemand auch nur in die Nähe
  eines Login-Prompts.
- **SSH/SFTP**: bleiben auf dem normalen öffentlichen Port, aber
  beschränkt auf eine feste Liste von Quell-IP-Bereichen (Firewall-
  Allowlist). Bewusst *kein* WireGuard-Zwang hier, damit der
  Ansible-Zugang nicht von einem funktionierenden VPN-Tunnel abhängt.

**Nur `ansible.builtin`-Module** — keine `community.*` (und auch keine
`ansible.posix`) Collections nötig. Docker, Firewall, WireGuard und SFTP
werden über die jeweiligen CLIs (`docker compose`, `firewall-cmd`/`ufw`,
`wg`/`wg-quick`, `setfacl`, `semanage`) via `ansible.builtin.command`
angesteuert.

## Struktur

```
.
├── ansible.cfg
├── site.yml                        # Playbook, führt alle sechs Rollen aus
├── inventory/
│   └── hosts.ini                   # VM(s) eintragen
├── group_vars/all/
│   ├── vars.yml                    # unkritische Konfiguration
│   └── vault.example.yml           # Vorlage für die verschlüsselte vault.yml
└── roles/
    ├── docker_engine/              # installiert Docker + Compose-Plugin
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── meta/main.yml
    ├── mssql_docker/                # kopiert Dateien, baut Image, startet Stack
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   ├── templates/
    │   │   ├── env.j2                    # rendert .env aus den Vault-Secrets
    │   │   └── docker-compose.yml.j2     # DB-Port an wireguard_server_ip gebunden
    │   ├── files/                  # 1:1 aus dem vorherigen Docker-Projekt
    │   │   ├── Dockerfile
    │   │   ├── entrypoint.sh
    │   │   ├── setup-admin-login.sql
    │   │   ├── setup-backup-job.sql
    │   │   └── toggle-sa.sh
    │   └── meta/main.yml
    ├── docker_cleanup/              # entfernt nicht mehr benötigte Images
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── meta/main.yml
    ├── wireguard_server/             # WireGuard-Hub, DB-Port nur über den Tunnel
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   ├── templates/wg0.conf.j2
    │   └── meta/main.yml
    ├── sftp_backup/                 # SFTP-only-Lesezugang auf ./backup
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   ├── templates/sftp-backup.conf.j2
    │   └── meta/main.yml
    └── ssh_allowlist/                # SSH/SFTP nur von festen Quell-CIDRs
        ├── defaults/main.yml
        ├── tasks/main.yml
        └── meta/main.yml
```

## Voraussetzungen auf dem Control-Node

- `ansible-core` (>= 2.14)
- `passlib` — wird für den `password_hash`-Filter benötigt, mit dem die
  `sftp_backup`-Rolle das Passwort des SFTP-Nutzers hasht:
  ```bash
  pip install passlib
  ```

## Einrichtung

### 1. Inventory anpassen

`inventory/hosts.ini`: IP/Hostname und SSH-User der Ziel-VM eintragen.

### 2. Vault mit Zugangsdaten anlegen

```bash
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
# Passwörter in vault.yml anpassen (sa, Admin-Login/-Passwort, SFTP-Backup-Nutzer)
ansible-vault encrypt group_vars/all/vault.yml
```

`group_vars/all/vars.yml` reicht diese Werte anschließend unter normalen
Namen (`sa_password`, `admin_login`, `admin_password`) durch, sodass Tasks
und Templates nicht wissen müssen, dass sie aus dem Vault stammen.

**Wichtig:** Das Admin-Passwort darf kein einfaches Anführungszeichen (`'`)
enthalten — `sqlcmd` ersetzt die `$(AdminPassword)`-Variable als reinen
Text, ein `'` würde das SQL-Skript zerbrechen.

`group_vars/all/vault.yml` (verschlüsselt) kann bedenkenlos ins Git-Repo,
solange sie tatsächlich verschlüsselt ist — nie die Klartext-Version
committen.

### 3. SSH/SFTP-Allowlist befüllen (Pflicht)

`ssh_allowed_cidrs` in `group_vars/all/vars.yml` **muss** vor dem ersten
Lauf mindestens die eigene Admin-/Büro-IP enthalten:

```yaml
ssh_allowed_cidrs:
  - 203.0.113.0/24      # z. B. Büro-/VPN-Netz
  - 198.51.100.42/32    # z. B. einzelner Admin-Rechner
```

Bleibt die Liste leer, bricht `ssh_allowlist` mit einem `assert` ab, statt
den Zugriff versehentlich komplett zu sperren — das Playbook schlägt dann
kontrolliert fehl, statt euch auszusperren. Trotzdem gilt: vor dem
produktiven Einsatz in einer zweiten, parallelen Sitzung testen (siehe
Abschnitt zur `ssh_allowlist`-Rolle weiter unten für Details zum
Sicherheitsnetz bei bestehenden Verbindungen).

### 4. Playbook ausführen

```bash
ansible-playbook site.yml --ask-vault-pass
```

Oder mit einer Passwortdatei (z. B. für CI):

```bash
ansible-playbook site.yml --vault-password-file ~/.ansible/vault_pass.txt
```

## Was die Rollen tun

### `docker_engine` (optional, aber für Rocky-VMs erforderlich)

Installiert Docker CE + Compose-Plugin **bevor** `mssql_docker` läuft
(Reihenfolge in `site.yml` fest verdrahtet). Unterstützt zwei OS-Familien:

**Debian/Ubuntu** — offizielles APT-Repo, wie bisher.

**RHEL/Rocky/AlmaLinux (`ansible_os_family == "RedHat"`)** — für Rocky
Linux 10 relevant, da dort standardmäßig **Podman** statt Docker läuft:

- Entfernt zuerst potenziell kollidierende Alt-Pakete (`docker`,
  `docker-client`, ..., `runc`) sowie **`podman-docker`** — das Paket, das
  `/usr/bin/docker` als Shim auf `podman` umleitet und sonst mit dem
  echten `docker-ce`-Binary kollidiert. **`podman` selbst bleibt
  installiert und unangetastet** — es wird nur der docker-CLI-Kompatibilitäts-
  Shim entfernt, nicht die Podman-Installation als Ganzes. Mit
  `docker_remove_podman_docker: false` abschaltbar.
- Installiert `kernel-modules-extra` und lädt `xt_addrtype` (per
  `/etc/modules-load.d/` dauerhaft + sofort per `modprobe`, kein Reboot
  nötig) — ohne dieses Modul scheitert Dockers iptables-Regelwerk auf
  Rocky-10-Minimal-/Cloud-Images typischerweise beim Start.
- Legt das offizielle Docker-Repo unter `/etc/yum.repos.d/docker-ce.repo`
  ab. **Wichtig:** Rocky/RHEL 10 haben (Stand 2026) noch keinen eigenen
  Docker-Repo-Pfad — `.../linux/rhel/10/...` liefert 404. Die Rolle nutzt
  daher standardmäßig den `centos`-Pfad
  (`docker_ce_repo_url` in `defaults/main.yml`), der für Rocky/RHEL 10
  nachweislich funktioniert (RPMs sind distributionsunabhängig
  kompatibel). Variable überschreiben, sobald Docker einen eigenen
  `rhel/10`-Pfad veröffentlicht.
- Installiert `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  docker-compose-plugin` via `ansible.builtin.dnf` (Rocky 10 läuft aktuell
  noch auf DNF4, das reguläre `dnf`-Modul ist also korrekt; für RHEL/Rocky-
  Versionen, die vollständig auf dnf5 umgestellt haben, müsste ggf. auf
  `ansible.builtin.dnf5` gewechselt werden).

Unbekannte OS-Familien (weder Debian noch RedHat) werden übersprungen und
nur per Debug-Meldung gemeldet — die Rolle bricht nicht ab, geht aber davon
aus, dass Docker dort bereits vorhanden ist.

Läuft insgesamt nur, wenn `docker_engine_manage: true` (Standard). Auf
`false` setzen (in `group_vars/all/vars.yml` oder per `-e`), wenn Docker auf
der VM bereits vorhanden ist. Am Ende wird zusätzlich mit
`docker compose version` geprüft, dass die CLI tatsächlich funktioniert
(schlägt sonst früh fehl, statt später mit unklarer Fehlermeldung in
`mssql_docker` zu scheitern).

### `mssql_docker`

1. Legt `{{ mssql_remote_dir }}` (Standard: `/opt/mssql-docker`) sowie die
   Unterordner `data/` und `backup/` auf der VM an.
2. Kopiert `Dockerfile` und die SQL-Skripte unverändert aus `files/`.
3. Rendert `docker-compose.yml` aus `templates/docker-compose.yml.j2` — der
   Container-Port wird an `wireguard_server_ip:{{ mssql_db_port }}` gebunden
   (nicht `0.0.0.0`), sodass er nur über den WireGuard-Tunnel erreichbar ist
   und garantiert mit dem von `wireguard_server` in der eigenen firewalld-
   Zone freigegebenen Port übereinstimmt.
4. Kopiert `entrypoint.sh` und `toggle-sa.sh` mit Ausführungsrechten (0755).
5. Rendert `.env` aus `templates/env.j2` mit den Vault-Secrets, Modus 0600.
   `no_log: true` verhindert, dass Passwörter im Ansible-Output auftauchen.
6. Baut das Image mit `docker compose build`.
7. Startet den Stack mit `docker compose up -d`.

Schritte 6+7 sind bewusst **immer** aktiv (nicht nur bei geänderten
Dateien) — `docker compose` ist selbst idempotent (Layer-Cache, keine
Neuerstellung ohne Änderung), sodass wiederholte Playbook-Läufe günstig
bleiben, auch ohne Ansible-Handler-Logik. Das `changed_when` auf beiden
Tasks ist eine Heuristik auf Basis der `docker compose`-Ausgabe (prüft auf
`Started`/`Created` bzw. `CACHED`) — für exakte Änderungserkennung reicht
das in der Praxis, ist aber kein Garant in jeder Compose-Version.

### `docker_cleanup`

Läuft direkt nach `mssql_docker`, um den durch `docker compose build`
entstandenen Layer-Müll wieder freizugeben:

- `docker image prune -a -f` — entfernt **alle** Images, die von keinem
  Container (weder laufend noch gestoppt) mehr referenziert werden. Das ist
  sicher: Das aktuell genutzte `my-mssql-with-agent:2022`-Image bleibt
  erhalten, solange der Container läuft. Mit `docker_cleanup_prune_all:
  false` auf das konservativere `docker image prune -f` (nur ungetaggte/
  dangling Images) umstellbar.
- `docker builder prune -f` — räumt zusätzlich den Build-Cache auf.
  Mit `docker_cleanup_builder_cache: false` abschaltbar.
- **Fasst nie Volumes an** — `mssql-log` und `mssql-secrets` (benannte
  Volumes mit Zertifikats-/Verschlüsselungsmaterial von SQL Server) sowie
  die bind-gemounteten `data/`/`backup/`-Ordner bleiben unangetastet. Es
  gibt bewusst kein `docker volume prune` oder `docker system prune`
  in dieser Rolle.
- Gibt am Ende in `Freigegebenen Speicherplatz melden` aus, wie viel
  Speicherplatz jeweils zurückgewonnen wurde.

### `wireguard_server`

Richtet die VM als reinen **Zugangs-Hub** für den SQL-Server-Port ein — kein
Router, kein Forwarding zu externen Zielen, `net.ipv4.ip_forward` bleibt
bewusst aus, weil Peers ausschließlich mit Diensten auf dieser VM selbst
sprechen.

1. Installiert `wireguard-tools` (RedHat-Familie: vorher `epel-release`,
   da `wireguard-tools` dort nicht in den Standard-Repos liegt). Das
   Kernelmodul selbst ist auf Rocky 10 bereits im Mainline-Kernel (≥5.6)
   enthalten — kein `kmod-wireguard`/ELRepo nötig. `modprobe wireguard`
   wird trotzdem geprüft und warnt (statt hart abzubrechen), falls es
   fehlschlägt.
2. Generiert **einmalig** ein Server-Schlüsselpaar (`wg genkey`/`wg
   pubkey`) in `/etc/wireguard/` — bei erneuten Läufen bleibt ein
   bestehendes Schlüsselpaar unangetastet (`creates:`-Guard).
3. Rendert `wg0.conf` aus `wireguard_peers` (Liste aus `name`,
   `public_key`, `allowed_ip`, optional `preshared_key`) — **Public Keys
   sind nicht geheim** und liegen deshalb bewusst in `vars.yml`, nicht im
   Vault. Private Keys werden clientseitig erzeugt und der Rolle nie
   mitgeteilt. `no_log: true` auf den relevanten Tasks, da die
   *Server*-Config den *Server*-Private-Key enthält.
4. Aktiviert/startet `wg-quick@wg0`.
5. **firewalld-Zonentrennung** (RedHat-Familie): legt eine eigene Zone
   (`wireguard`) an, ordnet ihr das `wg0`-Interface zu und öffnet
   `mssql_db_port` **ausschließlich dort** — die `public`-Zone (physisches
   Interface) bekommt diesen Port nie zu Gesicht. Der WireGuard-
   Handshake-Port selbst (`wireguard_listen_port/udp`, Standard `51820`)
   wird in der `public`-Zone geöffnet, da Peers von außen kommen müssen —
   das ist unproblematisch, weil WireGuard auf Pakete ohne gültigen
   Peer-Schlüssel schlicht nicht antwortet (kein Handshake, keine
   Angriffsfläche wie bei einem TCP-Login-Prompt).
6. **ufw (Debian, Bonus/best effort):** öffnet nur den Handshake-Port. ufw
   kennt kein Zonen-Konzept wie firewalld — auf Debian gibt es also kein
   Äquivalent zur Interface-basierten DB-Port-Beschränkung aus Schritt 5.
   Dort trägt allein die Portbindung an `wireguard_server_ip` (statt
   `0.0.0.0`) in `docker-compose.yml` den Schutz.
7. Gibt am Ende den **Server-Public-Key** aus, den jeder Client für seine
   eigene `[Peer]`-Sektion braucht.

Peer hinzufügen: Client generiert eigenes Schlüsselpaar
(`wg genkey | tee privatekey | wg pubkey > publickey`), teilt nur den
Public Key mit, der landet in `wireguard_peers` in `group_vars/all/
vars.yml`. Playbook erneut ausführen — bestehende Peers/das Server-
Schlüsselpaar bleiben unangetastet, nur die Peer-Liste in `wg0.conf` wird
neu geschrieben.

Mit `wireguard_server_manage: false` komplett abschaltbar (dann bräuchte
`docker-compose.yml` wieder eine andere Portbindung als
`wireguard_server_ip`, z. B. `0.0.0.0` oder `127.0.0.1` — siehe die
frühere Diskussion zu Bind-Optionen für den DB-Port).

### `sftp_backup`

Richtet einen **chroot-beschränkten, nur-lesenden SFTP-Zugang** auf
`{{ mssql_remote_dir }}/backup` ein — Zugangsdaten (`sftp_backup_login`,
`sftp_backup_password`) kommen aus dem Vault, genau wie die übrigen
Zugangsdaten.

1. Installiert `openssh-server` + `acl` und startet/aktiviert den
   SSH-Dienst (`sshd` auf RedHat, `ssh` auf Debian).
2. Legt den Nutzer mit **`nologin`-Shell** an (kein interaktives Login
   möglich) und einem gehashten Passwort (`password_hash('sha512')` —
   dafür muss **`passlib` auf dem Ansible-Control-Node** installiert sein,
   z. B. `pip install passlib`). `no_log: true` verhindert, dass der
   Passwort-Hash im Ansible-Output landet.
3. Setzt **POSIX-ACLs** auf das Backup-Verzeichnis (`setfacl -m
   u:<user>:rX ...` plus eine **Default-ACL** `-d` für künftige Dateien).
   Das ist nötig, weil `entrypoint.sh` bei jedem Container-Start
   `chown -R mssql:mssql backup` ausführt und damit die reguläre
   Unix-Gruppenzugehörigkeit für einen unabhängigen Host-Nutzer nutzlos
   macht — `chown` fasst bestehende ACL-Einträge aber nicht an, die
   Leserechte überleben also jeden Container-Neustart und jeden neuen
   Backup-Lauf.
4. Rendert einen sshd-Drop-in
   (`/etc/ssh/sshd_config.d/99-sftp-backup.conf`) mit einem
   `Match User`-Block:
   - `ChrootDirectory {{ mssql_remote_dir }}` — der Nutzer sieht nach dem
     Login nur `/backup` (relativ zur Chroot-Wurzel; auf dem echten
     Dateisystem `{{ mssql_remote_dir }}/backup`).
   - `ForceCommand internal-sftp -R` — das **`-R`** erzwingt Read-Only auf
     **Protokollebene**: sshd lehnt jeden Schreib-/Lösch-/Umbenennen-Versuch
     ab, unabhängig davon, was die Dateisystemrechte theoretisch erlauben
     würden. Zusammen mit den reinen Lese-ACLs ergibt das zwei unabhängige
     Sicherheitsebenen.
   - `AllowTcpForwarding no`, `X11Forwarding no`, `PermitTunnel no` —
     verhindert, dass der Account als Sprungbrett für Port-Forwarding
     missbraucht wird.
   - Jede Config-Änderung wird vor dem Schreiben mit `sshd -t` validiert
     (`validate:`-Parameter) und lädt `sshd`/`ssh` per Handler nur bei
     tatsächlicher Änderung neu — ein Tippfehler bricht damit nie eine
     laufende SSH-Verbindung.
5. **SELinux (nur RedHat-Familie, best effort):** Rocky 10 läuft
   standardmäßig mit enforcing SELinux. Ohne passenden Kontext auf dem
   Chroot-Verzeichnis bricht sshd die Verbindung sonst kommentarlos ab. Die
   Rolle prüft den Status (`getenforce`) und setzt bei Bedarf
   `ssh_home_t` per `semanage fcontext` + `restorecon` — nur wenn SELinux
   tatsächlich `Enforcing` ist, sonst wird dieser Teil übersprungen.
6. **Firewall:** keine eigene Portfreigabe mehr in dieser Rolle — SFTP läuft
   über den normalen SSH-Port, dessen Freigabe (quellbeschränkt) übernimmt
   `roles/ssh_allowlist` (läuft danach). Eine pauschale Freigabe hier würde
   die dortige Allowlist unterlaufen.

Zugriff testen:

```bash
sftp -P 22 backup-reader@<vm>
sftp> ls
sftp> get <dateiname>.bak
sftp> put test.txt   # muss mit "Permission denied" fehlschlagen
```

Mit `sftp_backup_manage: false` komplett abschaltbar.

### `ssh_allowlist`

Beschränkt SSH — und damit auch SFTP, da beide über denselben Port laufen
— auf eine feste Liste von Quell-IP-Bereichen (`ssh_allowed_cidrs`).

- **Sicherheitsbremse:** Die Rolle bricht mit einem `assert` ab, wenn
  `ssh_allowed_cidrs` leer ist, statt den Zugriff versehentlich komplett
  zu sperren (inklusive Ansibles eigenem Zugang). **Die eigene Admin-/
  Büro-IP muss vor dem Ausrollen in dieser Liste stehen.**
- **Wichtiger Kniff bei firewalld:** Rocky-Cloud-Images haben in der
  `public`-Zone standardmäßig den Service `ssh` freigegeben — das erlaubt
  Zugriff von *jeder* Quelle. Eine zusätzliche Rich-Rule allein würde
  daran nichts ändern (die breite Regel lässt weiterhin alle rein), die
  Rolle entfernt den `ssh`-Service-Eintrag deshalb explizit
  (`firewall-cmd --remove-service=ssh`), bevor sie pro CIDR eine
  quellbeschränkte Rich-Rule hinzufügt
  (`rule family="ipv4|ipv6" source address="..." port protocol="tcp"
  port="22" accept` — Familie wird anhand des `:` im CIDR automatisch
  erkannt).
- **ufw (Debian, Bonus):** entfernt analog das `OpenSSH`-Profil und eine
  eventuelle pauschale `22/tcp`-Regel, bevor pro CIDR eine `ufw allow
  from ... to any port 22 proto tcp` ergänzt wird.
- Reagiert idempotent: bereits vorhandene Rich-Rules/ufw-Regeln werden
  nicht doppelt angelegt, Reload nur bei tatsächlicher Änderung.
- **Sicherheitsnetz:** Bereits bestehende SSH-Verbindungen (inklusive der,
  über die Ansible selbst gerade läuft) werden von einer
  Firewall-Änderung normalerweise **nicht** gekappt — `ESTABLISHED`-Traffic
  bleibt erlaubt, unabhängig von neuen Regeln. Das gibt eine gewisse
  Sicherheit, falls die eigene IP fälschlich fehlt — ersetzt aber keinen
  sorgfältigen Test in einer zweiten, parallelen Sitzung vor dem
  produktiven Einsatz.

Mit `ssh_allowlist_manage: false` komplett abschaltbar (dann bleibt die
default-permissive SSH-Freigabe der VM unangetastet bestehen).

## Variablen (in `group_vars/all/vars.yml` oder Rollen-`defaults`)

| Variable              | Standard             | Bedeutung                                      |
|------------------------|----------------------|-------------------------------------------------|
| `mssql_remote_dir`     | `/opt/mssql-docker`  | Zielverzeichnis auf der VM                      |
| `mssql_disable_sa`     | `true`                | steuert `DISABLE_SA` in der `.env`              |
| `mssql_db_port`        | `1433`                | Port, an `wireguard_server_ip` gebunden (Docker-Portmapping + firewalld-Zone) |
| `docker_engine_manage` | `true`                | Docker-Installation aktivieren/überspringen     |
| `docker_ce_repo_url`   | centos-Repo (s. o.)  | nur RedHat-Familie: Quelle für `docker-ce.repo` |
| `docker_remove_podman_docker` | `true`         | nur RedHat-Familie: `podman-docker`-Shim entfernen |
| `docker_cleanup_manage`      | `true`          | Image-Cleanup aktivieren/überspringen           |
| `docker_cleanup_prune_all`   | `true`          | `-a` bei `docker image prune` (alle ungenutzten statt nur dangling) |
| `docker_cleanup_builder_cache` | `true`        | zusätzlich `docker builder prune -f` ausführen  |
| `wireguard_server_manage` | `true`             | WireGuard-Setup aktivieren/überspringen         |
| `wireguard_server_ip`  | `10.10.0.1`           | Tunnel-IP der VM; DB-Port wird exakt daran gebunden |
| `wireguard_server_prefix` | `24`               | Präfixlänge des Overlay-Netzes                  |
| `wireguard_listen_port` | `51820`              | UDP-Port für den WireGuard-Handshake (öffentlich) |
| `wireguard_peers`      | `[]`                  | Liste von `{name, public_key, allowed_ip[, preshared_key]}` |
| `sftp_backup_manage`  | `true`                | SFTP-Zugang aktivieren/überspringen             |
| `sftp_backup_port`    | `22`                   | informativ, muss zu `ssh_allowlist_port` passen |
| `ssh_allowlist_manage` | `true`                | SSH/SFTP-Allowlist aktivieren/überspringen      |
| `ssh_allowlist_port`  | `22`                   | Port, auf den die Allowlist angewendet wird     |
| `ssh_allowed_cidrs`   | `[]` (**muss befüllt werden**) | erlaubte Quell-IP-Bereiche für SSH/SFTP |
| `sa_password`          | *(aus Vault)*         | initiales sa-Passwort (Bootstrap, dann gesperrt)|
| `admin_login`          | *(aus Vault)*         | Name des sysadmin-Ersatz-Logins                 |
| `admin_password`       | *(aus Vault)*         | Passwort des Ersatz-Logins                      |
| `sftp_backup_login`    | *(aus Vault)*         | Name des SFTP-only-Nutzers                      |
| `sftp_backup_password` | *(aus Vault)*         | Passwort des SFTP-only-Nutzers                  |

## sa temporär wieder aktivieren

Nach dem Deployment genauso nutzbar wie vorher, nur jetzt remote:

```bash
ssh deploy@<vm> "cd /opt/mssql-docker && sudo docker exec -it mssql-server /usr/src/app/toggle-sa.sh enable"
# ... Tool nutzen, das sa braucht ...
ssh deploy@<vm> "cd /opt/mssql-docker && sudo docker exec -it mssql-server /usr/src/app/toggle-sa.sh disable"
```

## Datenbank-Port ändern

```bash
ansible-playbook site.yml --ask-vault-pass -e mssql_db_port=14330
```

Oder dauerhaft in `group_vars/all/vars.yml` anpassen. Zwei Dinge dabei
beachten:

- `docker compose up -d` erkennt die geänderte Portmapping-Zeile in der neu
  gerenderten `docker-compose.yml` und startet den Container neu, damit der
  neue Port tatsächlich gebunden wird.
- `wireguard_server` **öffnet nur den neuen Port** in der `wireguard`-Zone
  — der alte bleibt dort offen (die Rolle schließt nichts automatisch, um
  keine anderen, eventuell absichtlich offenen Ports zu gefährden). Bei
  Bedarf manuell schließen, z. B.: `firewall-cmd --permanent
  --zone=wireguard --remove-port=1433/tcp && firewall-cmd --reload`. Da
  der Port ohnehin nur über den WireGuard-Tunnel erreichbar ist, ist das
  Risiko eines offenen alten Ports deutlich geringer als bei einer
  öffentlichen Freigabe.

## WireGuard-Peer hinzufügen/entfernen

**Hinzufügen:**

```bash
# auf dem Client-Gerät
wg genkey | tee privatekey | wg pubkey > publickey
```

Den Inhalt von `publickey` (nicht `privatekey`!) in `wireguard_peers` in
`group_vars/all/vars.yml` eintragen, dann `ansible-playbook site.yml`
erneut laufen lassen. Der Client braucht zusätzlich eine eigene
`wg0.conf` mit `Endpoint = <VM-IP>:{{ wireguard_listen_port }}` und dem
**Server**-Public-Key (wird am Ende des `wireguard_server`-Laufs
ausgegeben).

**Entfernen:** den entsprechenden Eintrag aus `wireguard_peers` löschen
und das Playbook erneut ausführen — der Peer verschwindet aus `wg0.conf`,
der Zugriff ist ab dem nächsten `wg-quick`-Neustart (passiert automatisch
via Handler) gesperrt.

## SSH/SFTP-Allowlist pflegen

```bash
ansible-playbook site.yml --ask-vault-pass \
  -e '{"ssh_allowed_cidrs": ["203.0.113.0/24", "198.51.100.42/32"]}'
```

Oder dauerhaft in `group_vars/all/vars.yml`. Auch hier gilt: bereits
erlaubte CIDRs, die aus der Liste entfernt werden, werden **nicht**
automatisch aus der Firewall gelöscht (nur additiv, aus denselben
Sicherheitsgründen wie oben) — bei Bedarf manuell entfernen:
`firewall-cmd --permanent --zone=public --remove-rich-rule='rule
family="ipv4" source address="..." port protocol="tcp" port="22"
accept' && firewall-cmd --reload`.

## Erneutes Ausrollen / Aktualisieren

Einfach `ansible-playbook site.yml` erneut laufen lassen — alle Tasks sind
idempotent. Geänderte Skripte/SQL-Dateien werden überschrieben, `docker
compose build` erkennt Layer-Änderungen und baut nur das Nötige neu, `up -d`
ersetzt den Container nur, wenn sich tatsächlich etwas geändert hat.
