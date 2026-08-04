# Ansible: MSSQL-Server (Docker + Agent + Backups) deployen

Deployt den zuvor gebauten MSSQL-Docker-Stack (Dockerfile, Compose-Datei,
SQL-Server-Agent-Backup-Job, sa-Sperrung) automatisiert auf eine VM. Räumt
nach dem Build nicht mehr benötigte Docker-Images auf, gibt den
konfigurierbaren Datenbank-Port in der Host-Firewall frei, und richtet
einen chroot-beschränkten SFTP-only-Nutzer mit Lesezugriff auf die
Backup-Dateien ein.

**Nur `ansible.builtin`-Module** — keine `community.*` (und auch keine
`ansible.posix`) Collections nötig. Docker, Firewall und SFTP werden über
die jeweiligen CLIs (`docker compose`, `firewall-cmd`/`ufw`, `setfacl`,
`semanage`) via `ansible.builtin.command` angesteuert.

## Struktur

```
.
├── ansible.cfg
├── site.yml                        # Playbook, führt alle vier Rollen aus
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
    │   │   └── docker-compose.yml.j2     # Host-Port aus mssql_db_port
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
    ├── firewall_db_port/            # gibt mssql_db_port in der Host-Firewall frei
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── meta/main.yml
    └── sftp_backup/                 # SFTP-only-Lesezugang auf ./backup
        ├── defaults/main.yml
        ├── tasks/main.yml
        ├── handlers/main.yml
        ├── templates/sftp-backup.conf.j2
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

### 3. Playbook ausführen

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
   Host-Port kommt aus `mssql_db_port` (Standard `1433`), damit er garantiert
   mit dem von `firewall_db_port` freigegebenen Port übereinstimmt.
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

### `firewall_db_port`

Gibt `mssql_db_port/tcp` (Standard `1433`) in der Host-Firewall der VM frei
— läuft nach `mssql_docker`, damit der freigegebene Port garantiert dem
tatsächlich in `docker-compose.yml` veröffentlichten entspricht.

- **Primäres Ziel: firewalld** (`ansible_os_family == "RedHat"`, Rockys
  Standard-Firewall). Prüft per `firewall-cmd --permanent --query-port`,
  ob der Port schon freigegeben ist, fügt ihn nur bei Bedarf hinzu
  (`--add-port`) und lädt die Firewall nur bei tatsächlicher Änderung neu
  (`--reload`) — mehrfache Playbook-Läufe erzeugen also kein unnötiges
  Reload.
- **Bonus: ufw** (`ansible_os_family == "Debian"`) — analog, aber weniger
  intensiv getestet, da die Ziel-VM Rocky ist.
- Bewusst **kein** `ansible.posix.firewalld`-Modul, sondern reine
  `firewall-cmd`/`ufw`-CLI-Aufrufe über `ansible.builtin.command` — `ansible.
  posix` ist eine separate Collection und fällt damit unter dieselbe
  "nur Standard-Ansible-Tools"-Vorgabe wie `community.*`.
- Ist weder firewalld noch ufw aktiv (z. B. weil der Zugriff über eine
  Cloud-Security-Group statt Host-Firewall geregelt wird), gibt die Rolle
  nur eine Debug-Meldung aus und bricht nicht ab. Mit
  `firewall_manage: false` komplett abschaltbar.

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
6. **Firewall:** gibt `sftp_backup_port/tcp` (Standard `22`, derselbe Port
   wie SSH — SFTP ist kein eigenständiges Protokoll, sondern läuft über
   die SSH-Verbindung) in der Host-Firewall frei. Exakt dasselbe Muster wie
   in `firewall_db_port` (firewalld primär via `firewall-cmd
   --permanent --query-port` / `--add-port`, ufw als Bonus für Debian,
   Reload nur bei tatsächlicher Änderung), aber mit eigener Variable
   (`sftp_backup_firewall_manage`) unabhängig von `firewall_manage`
   steuerbar — falls der SFTP-Zugang z. B. nur aus dem internen Netz
   erreichbar sein soll, während der DB-Port öffentlich bleibt (oder
   umgekehrt). Läuft üblicherweise ins Leere, da Port 22 auf den meisten
   VMs (inkl. der, über die Ansible selbst verbindet) ohnehin schon offen
   ist — schadet aber nicht und deckt den Fall ab, dass SFTP absichtlich
   auf einem anderen Port als der administrative SSH-Zugang laufen soll.

Zugriff testen:

```bash
sftp -P 22 backup-reader@<vm>
sftp> ls
sftp> get <dateiname>.bak
sftp> put test.txt   # muss mit "Permission denied" fehlschlagen
```

Mit `sftp_backup_manage: false` komplett abschaltbar (schließt auch die
Firewall-Freigabe mit ein). Nur die Firewall-Freigabe separat abschalten:
`sftp_backup_firewall_manage: false`.

## Variablen (in `group_vars/all/vars.yml` oder Rollen-`defaults`)

| Variable              | Standard             | Bedeutung                                      |
|------------------------|----------------------|-------------------------------------------------|
| `mssql_remote_dir`     | `/opt/mssql-docker`  | Zielverzeichnis auf der VM                      |
| `mssql_disable_sa`     | `true`                | steuert `DISABLE_SA` in der `.env`              |
| `mssql_db_port`        | `1433`                | Host-Port für Docker-Portmapping **und** Firewall-Freigabe |
| `docker_engine_manage` | `true`                | Docker-Installation aktivieren/überspringen     |
| `docker_ce_repo_url`   | centos-Repo (s. o.)  | nur RedHat-Familie: Quelle für `docker-ce.repo` |
| `docker_remove_podman_docker` | `true`         | nur RedHat-Familie: `podman-docker`-Shim entfernen |
| `docker_cleanup_manage`      | `true`          | Image-Cleanup aktivieren/überspringen           |
| `docker_cleanup_prune_all`   | `true`          | `-a` bei `docker image prune` (alle ungenutzten statt nur dangling) |
| `docker_cleanup_builder_cache` | `true`        | zusätzlich `docker builder prune -f` ausführen  |
| `firewall_manage`     | `true`                | Firewall-Freigabe aktivieren/überspringen       |
| `sftp_backup_manage`  | `true`                | SFTP-Zugang aktivieren/überspringen             |
| `sftp_backup_port`    | `22`                   | Port, der für SFTP in der Firewall freigegeben wird |
| `sftp_backup_firewall_manage` | `true`         | nur die Firewall-Freigabe für SFTP aktivieren/überspringen |
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
- `firewall_db_port` **öffnet nur den neuen Port** — der alte bleibt in der
  Firewall offen (die Rolle schließt nichts automatisch, um keine anderen,
  eventuell absichtlich offenen Ports zu gefährden). Bei Bedarf manuell
  schließen, z. B.: `firewall-cmd --permanent --remove-port=1433/tcp &&
  firewall-cmd --reload`.

## Erneutes Ausrollen / Aktualisieren

Einfach `ansible-playbook site.yml` erneut laufen lassen — alle Tasks sind
idempotent. Geänderte Skripte/SQL-Dateien werden überschrieben, `docker
compose build` erkennt Layer-Änderungen und baut nur das Nötige neu, `up -d`
ersetzt den Container nur, wenn sich tatsächlich etwas geändert hat.
