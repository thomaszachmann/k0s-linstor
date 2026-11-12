#import "../lib.typ": *

#kapitel(
  [Der LINSTOR-Controller ohne Single Point of Failure],
  ziel: [Die Datenbank des Controllers liegt auf einer eigenen DRBD-Ressource. drbd-reactor startet den Controller samt VIP dort, wo diese Ressource aktiv ist, und schwenkt bei einem Ausfall in Sekunden auf einen anderen Node.],
  zeit: [40 Minuten],
  braucht: [Die registrierten Nodes aus Kapitel 5, die Storage-Pools aus Kapitel 7 Abschnitt „Storage-Pools anlegen“],
)

#hinweis("Reihenfolge", akzent, akzent-hell)[
  `linstor_db` ist selbst eine LINSTOR-Ressource und braucht deshalb einen Storage-Pool. Lege zuerst die beiden Pools aus dem Abschnitt „Storage-Pools anlegen“ in Kapitel 7 an und kehre dann hierher zurück.
]

== Das Prinzip

Der LINSTOR-Controller ist zustandslos bis auf seine Datenbank, eine H2-Datei unter `/var/lib/linstor`. Wer diese Datei hat, kann Controller sein. Die Idee:

+ Die Datenbank liegt auf einer kleinen DRBD-Ressource `linstor_db`, die auf allen drei Workern repliziert ist.
+ Auf dem Node, auf dem `linstor_db` Primary ist, wird sie nach `/var/lib/linstor` gemountet und der Controller gestartet.
+ Eine virtuelle IP zieht mit. Clients und der CSI-Treiber sprechen immer mit der VIP.
+ drbd-reactor überwacht `linstor_db`. Fällt der aktive Node aus, macht ein anderer Node die Ressource zum Primary und startet die Kette dort.

#warum[
  DRBD sorgt selbst dafür, dass nur ein Node Primary sein kann, solange er Quorum hat. Damit gibt es nie zwei Controller gleichzeitig, auch nicht bei einer Netztrennung. Ein Pacemaker-Cluster ist dafür nicht nötig. Das ist das Muster dieses Buchs: ein aktiver Controller, die Datenbank auf mehreren Hosts repliziert, eine disklose Witness am dritten Standort.
]

== Die Ressource linstor_db

#cmd("k0s-w1")[```bash
linstor resource-group create --storage-pool pool_data --place-count 3 \
  --diskless-on-remaining true linstor-db-grp
linstor resource-group drbd-options --auto-promote=no --quorum=majority \
  --on-suspended-primary-outdated=force-secondary \
  --on-no-quorum=io-error --on-no-data-accessible=io-error linstor-db-grp
linstor volume-group create linstor-db-grp
linstor resource-group spawn-resources linstor-db-grp linstor_db 200M
```][Eine Resource-Group ist eine Vorlage. `--place-count 3` legt drei Kopien mit Daten an, `--diskless-on-remaining` gibt allen übrigen Nodes, hier der Witness, eine Kopie ohne Daten, die beim Quorum mitzählt.]

#tabelle(
  (auto, 1fr),
  ([Option], [Bedeutung]),
  [`auto-promote=no`], [Niemand wird automatisch Primary, nur weil er das Gerät öffnet. Das übernimmt allein drbd-reactor.],
  [`quorum=majority`], [Schreiben nur, wenn die Mehrheit der Knoten erreichbar ist. Bei vier Stimmen also mindestens drei.],
  [`on-no-quorum=io-error`], [Verliert der Primary sein Quorum, bekommt der Controller sofort Fehler statt zu hängen. drbd-reactor erkennt das und gibt ab.],
  [`on-suspended-primary-outdated=force-secondary`], [Ein abgeschnittener Primary, der wieder auftaucht und veraltet ist, wird zwangsweise Secondary.],
)

#cmd("k0s-w1")[```bash
linstor resource list -r linstor_db
```][Zeigt, wo die Ressource liegt.]

#pruefe[
```
│ ResourceName │ Node     │ Layers       │ Usage  │ Conns │    State │ Vote │
│ linstor_db   │ k0s-ctrl │ DRBD,STORAGE │ Unused │ Ok    │ Diskless │ Yes  │
│ linstor_db   │ k0s-w1   │ DRBD,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
│ linstor_db   │ k0s-w2   │ DRBD,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
│ linstor_db   │ k0s-w3   │ DRBD,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
```
Drei Kopien mit Daten, eine ohne. Alle vier haben eine Stimme (`Vote: Yes`).
]

Jetzt siehst du auch, ob der Witness-Pfad aus Kapitel 5 wirkt:

#cmd("k0s-w1")[```bash
sudo drbdsetup show linstor_db | grep -E "_this_host ipv4|_remote_host ipv4"
```][Zeigt für jede Verbindung die lokale und die entfernte Adresse.]

#pruefe[
```
            _this_host ipv4 172.16.0.186:7000;
            _remote_host ipv4 172.16.0.176:7000;
            _this_host ipv4 10.10.0.11:7000;
            _remote_host ipv4 10.10.0.12:7000;
            _this_host ipv4 10.10.0.11:7000;
            _remote_host ipv4 10.10.0.13:7000;
```
Zur Witness über `172.16.0.x`, zu den anderen Workern über `10.10.0.x`. So soll es sein.
]

== Die Datenbank umziehen

Der Controller läuft noch auf `k0s-w1` mit seiner Datenbank auf der Systemplatte. Jetzt wird sie auf `linstor_db` kopiert.

#datei("lab/linstor/var-lib-linstor.mount", ```
[Unit]
Description=Filesystem for the LINSTOR controller

[Mount]
What=/dev/drbd/by-res/linstor_db/0
Where=/var/lib/linstor
```, erklaerung: [Eine systemd-Mount-Unit. drbd-reactor startet sie, bevor er den Controller startet. Der Dateiname muss zum Pfad passen: `/var/lib/linstor` wird zu `var-lib-linstor.mount`.])

#cmd("Mac")[```bash
scp lab/linstor/var-lib-linstor.mount k0s-w1:/tmp/
ssh k0s-w1 'sudo install -m 644 /tmp/var-lib-linstor.mount /etc/systemd/system/'
ssh k0s-w1 'sudo systemctl daemon-reload'
```][Dasselbe für `k0s-w2` und `k0s-w3`. Aktiviere die Unit *nicht*, sie wird nur von drbd-reactor gestartet.]

#cmd("k0s-w1")[```bash
sudo systemctl disable --now linstor-controller
sudo mv /var/lib/linstor /var/lib/linstor.orig
sudo mkdir /var/lib/linstor
sudo drbdadm primary linstor_db
sudo mkfs.ext4 -b 4096 /dev/drbd/by-res/linstor_db/0
sudo systemctl start var-lib-linstor.mount
sudo cp -a /var/lib/linstor.orig/. /var/lib/linstor/
sudo umount /var/lib/linstor
sudo drbdadm secondary linstor_db
```][Controller stoppen, alte Datenbank zur Seite legen, `linstor_db` zum Primary machen, ein Dateisystem anlegen, mounten, die Datenbank hineinkopieren und alles wieder freigeben. Ab jetzt ist der Controller aus, bis drbd-reactor ihn startet.]

#falle[
  `/var/lib/linstor.orig` bleibt als Sicherung liegen. Lösche es erst, wenn der Controller einige Tage stabil auf `linstor_db` läuft. Und starte nie wieder einen Controller, der darauf zeigt: Er hätte einen veralteten Stand.
]

== drbd-reactor einrichten

Für die VIP nutzt drbd-reactor den bewährten OCF-Agenten `IPaddr2` aus dem Pacemaker-Umfeld. Er steckt im Paket `resource-agents-base`.

#cmd("k0s-w1")[```bash
sudo apt-get install -y resource-agents-base
```][Auf allen drei Controller-Kandidaten.]

#datei("lab/linstor/linstor_db.toml", ```toml
# drbd-reactor: genau ein aktiver LINSTOR-Controller, dort wo linstor_db Primary ist
[[promoter]]
id = "linstor_db"
[promoter.resources.linstor_db]
start = [
  "var-lib-linstor.mount",
  "ocf:heartbeat:IPaddr2 linstor_vip ip=10.10.0.100 cidr_netmask=24 nic=ens19",
  "linstor-controller.service",
]
on-drbd-demote-failure = "reboot"
stop-services-on-exit = true
```, erklaerung: [
  `start` ist eine Kette: Mount, dann VIP, dann Controller. Beim Abschalten geht es rückwärts.
  Die VIP liegt im Storage-Netz. Der CSI-Treiber erreicht sie, weil jeder Worker eine Adresse in diesem Netz hat.
  `on-drbd-demote-failure = "reboot"`: Lässt sich `linstor_db` beim Abgeben nicht zum Secondary machen, weil etwas das Gerät festhält, startet der Node neu. Das ist hart, aber besser als ein Node, der die Datenbank nicht loslässt.
  `stop-services-on-exit`: Wird drbd-reactor selbst gestoppt, fährt er auch die Kette herunter.
])

#cmd("Mac")[```bash
scp lab/linstor/linstor_db.toml k0s-w1:/tmp/
ssh k0s-w1 'sudo install -m 644 /tmp/linstor_db.toml /etc/drbd-reactor.d/'
```][Dasselbe für `k0s-w2` und `k0s-w3`.]

Bevor drbd-reactor startet, stellst du alle Clients auf die VIP um:

#datei("/etc/linstor/linstor-client.conf (auf w1, w2, w3)", ```
[global]
controllers=10.10.0.100
```)

#datei("/etc/linstor/linstor-client.conf (auf k0s-ctrl)", ```
[global]
controllers=172.16.0.186,172.16.0.36,172.16.0.72
```, erklaerung: [Die Witness hat keine Adresse im Storage-Netz und erreicht die VIP nicht. Sie bekommt die Liste der Kandidaten und probiert sie der Reihe nach durch.])

#cmd("k0s-w1")[```bash
sudo systemctl enable drbd-reactor
sudo systemctl restart drbd-reactor
```][Auf allen drei Kandidaten. Der erste, der `linstor_db` zum Primary machen kann, startet die Kette.]

#cmd("k0s-w1")[```bash
sudo drbd-reactorctl status linstor_db
ip -br addr show ens19
```][Zeigt die Kette und ob die VIP auf diesem Node liegt.]

#pruefe[
```
Promoter: Resource linstor_db currently active on this node
● drbd-services@linstor_db.target
● ├─ drbd-promote@linstor_db.service
● ├─ var-lib-linstor.mount
● ├─ ocf.rs@linstor_vip_linstor_db.service
● └─ linstor-controller.service
ens19            UP             10.10.0.11/24 10.10.0.100/24 ...
```
Auf `k0s-w2` und `k0s-w3` steht stattdessen `currently active on node 'k0s-w1'` und leere Kreise.
]

#cmd("k0s-w2")[```bash
linstor node list
```][Ein Befehl von einem anderen Node über die VIP. Antwortet er mit allen vier Nodes `Online`, ist der Umzug gelungen.]

== Den Failover ausprobieren

`drbd-reactorctl evict` zwingt den aktiven Node, abzugeben. Das ist der geplante Weg, etwa vor einer Wartung.

#cmd("k0s-w1")[```bash
sudo drbd-reactorctl evict linstor_db
```][Fährt die Kette auf `k0s-w1` herunter und wartet, bis ein anderer Node übernommen hat.]

#pruefe[
```
Node 'k0s-w3' took over
Re-enabling linstor_db
```
Im Lab war der Controller nach *15 Sekunden* wieder über die VIP erreichbar. Laufende Volumes merken davon nichts: DRBD repliziert weiter, auch ohne Controller. Nur neue Volumes, Löschungen und Änderungen müssen warten.
]

#cmd("k0s-w3")[```bash
sudo drbd-reactorctl status linstor_db | head -2
linstor resource list -r linstor_db
```][Die Ressource ist jetzt auf `k0s-w3` in Benutzung.]

#pruefe[
```
Promoter: Resource linstor_db currently active on this node
│ linstor_db   │ k0s-w3   │ DRBD,STORAGE │ InUse  │ Ok    │ UpToDate │ Yes  │
```
]

#warum[
  Der wichtigste Satz dieses Kapitels: *Fällt der Controller aus, laufen alle Volumes weiter.* Der Controller verwaltet nur. Die Daten fließen direkt zwischen den DRBD-Modulen der Nodes. Wenn der Controller hängt, hast du Zeit. Panik ist erst angebracht, wenn `drbdadm status` auf den Nodes Probleme zeigt.
]

Den ungeplanten Fall, einen hart ausgeschalteten Node mit aktivem Controller, spielst du in Kapitel 10 durch.

#gelernt(
  [Der Controller ist austauschbar, solange seine Datenbank repliziert ist.],
  [drbd-reactor startet Mount, VIP und Controller als Kette auf dem Primary von `linstor_db`.],
  [DRBD-Quorum verhindert zwei Controller gleichzeitig.],
  [`drbd-reactorctl status` zeigt, wo der Controller läuft. `evict` schiebt ihn geplant weiter.],
  [Ein Controller-Ausfall stoppt keine laufenden Volumes.],
)
