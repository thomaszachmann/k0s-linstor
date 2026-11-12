#import "../lib.typ": *

#kapitel(
  [LINSTOR und DRBD auf den Hosts],
  ziel: [DRBD 9 und LINSTOR 1.33.3 laufen als Pakete direkt auf den VMs, außerhalb von Kubernetes. Vier Satellites sind beim Controller registriert, die Replikation läuft über das Storage-Netz, die Witness über das Management-Netz.],
  zeit: [45 Minuten, davon etwa 25 Minuten Warten auf den Modul-Build],
  braucht: [Die VMs aus Kapitel 2],
)

== Warum LINSTOR außerhalb von Kubernetes

Piraeus kann LINSTOR komplett in Kubernetes betreiben: Controller und Satellites als Pods, DRBD per Container geladen. Dieses Buch macht es bewusst anders. LINSTOR läuft als normale systemd-Dienste auf den Hosts, und Kubernetes bekommt nur den CSI-Treiber.

#warum[
  Storage ist das Fundament unter dem Cluster. Läuft LINSTOR im Cluster, hängt der Speicher von Kubernetes ab und Kubernetes vom Speicher. Bei einem Ausfall des Clusters, bei einem Update von k0s oder bei einem kaputten Operator stehen dann auch die Volumes. Auf den Hosts überlebt LINSTOR all das. Du kannst k0s neu aufsetzen, und die Daten bleiben, wo sie sind. Der Preis: Du verwaltest LINSTOR selbst, mit Paketen, systemd und später Ansible.
]

#tabelle(
  (auto, auto, 1fr),
  ([Komponente], [Wo], [Aufgabe]),
  [`drbd` (Kernelmodul)], [alle vier VMs], [Repliziert Blöcke zwischen den Nodes.],
  [`linstor-satellite`], [alle vier VMs], [Führt aus, was der Controller verlangt: LVs anlegen, DRBD konfigurieren.],
  [`linstor-controller`], [w1, w2, w3 (Kandidaten)], [Hält den gewünschten Zustand in seiner Datenbank. Läuft immer nur auf einem Node.],
  [`drbd-reactor`], [w1, w2, w3], [Startet den Controller dort, wo seine Datenbank gerade aktiv ist (Kapitel 6).],
  [`linstor-client`], [alle vier VMs], [Die Kommandozeile `linstor`.],
)

== Woher die Pakete kommen

Für Ubuntu pflegt LINBIT ein PPA mit DRBD, drbd-utils, drbd-reactor und LINSTOR. Das PPA enthält aber immer nur die neueste Version. Ältere Builds löscht Launchpad. Im November 2026 heißt das: LINSTOR 1.35.3, nicht 1.33.3.

LINBITs öffentliches Debian-Repository hält dagegen auch ältere Versionen vor. Die LINSTOR-Pakete sind reines Java (`_all.deb`) und laufen auf Ubuntu genauso. Das Buch nimmt daher:

#tabelle(
  (auto, auto, 1fr),
  ([Paket], [Version], [Quelle]),
  [`drbd-dkms`], [9.3.4], [PPA `linbit/linbit-drbd9-stack`],
  [`drbd-utils`], [9.36.0~rc.1], [PPA; die Ubuntu-Version 9.22 ist zu alt für DRBD 9.3],
  [`drbd-reactor`], [1.12.0], [PPA],
  [`linstor-client`], [1.29.1], [PPA],
  [`linstor-common`, `-satellite`, `-controller`], [1.33.3], [`packages.linbit.com/public`, Zweig bookworm],
)

#falle[
  Wer in einer Umgebung mit fester LINSTOR-Version arbeitet, kann sich nicht auf das PPA verlassen. Ein `apt upgrade` zieht dort sofort die neueste Version, und eine einmal ersetzte Version ist weg. In Produktion legt die Automatisierung, etwa Ansible (Kapitel 16), die Version fest. Im Lab pinnst du sie mit `apt-mark hold`.
]

== Die Pakete installieren

Die folgenden Befehle zeigt das Buch für `k0s-w1`. Auf `k0s-w2` und `k0s-w3` sind sie identisch. Auf `k0s-ctrl` lässt du das Paket `linstor-controller` weg, denn die Witness wird nie Controller.

#cmd("k0s-w1")[```bash
sudo add-apt-repository -y ppa:linbit/linbit-drbd9-stack
sudo apt-get update
sudo apt-get install -y linux-headers-$(uname -r) drbd-dkms drbd-utils \
  drbd-reactor linstor-client lvm2 thin-provisioning-tools default-jre-headless
```][`drbd-dkms` baut das DRBD-Modul passend zum laufenden Kernel, deshalb die Header. Das dauert auf einer kleinen VM sechs bis sieben Minuten. `default-jre-headless` ist die Java-Laufzeit für LINSTOR.]

#cmd("k0s-w1")[```bash
cd /tmp
B=https://packages.linbit.com/public/dists/bookworm/misc/pool
curl -sSfLO $B/linstor-common_1.33.3-1_all.deb
curl -sSfLO $B/linstor-satellite_1.33.3-1_all.deb
curl -sSfLO $B/linstor-controller_1.33.3-1_all.deb
sudo apt-get install -y ./linstor-common_1.33.3-1_all.deb \
  ./linstor-satellite_1.33.3-1_all.deb ./linstor-controller_1.33.3-1_all.deb
sudo apt-mark hold linstor-common linstor-satellite linstor-controller drbd-dkms drbd-utils
```][`apt-get install ./datei.deb` installiert lokale Pakete und löst ihre Abhängigkeiten trotzdem aus den Repositories auf. `apt-mark hold` schützt die Versionen vor `apt upgrade`. Updates machst du in Kapitel 15 bewusst.]

#cmd("k0s-w1")[```bash
sudo modprobe drbd
echo drbd | sudo tee /etc/modules-load.d/drbd.conf
cat /proc/drbd
```][Lädt das Modul jetzt und bei jedem Start.]

#pruefe[
```
version: 9.3.4 (api:2/proto:118-125)
GIT-hash: e59b287b199f7224468af85b68a10e83c68213f5 build by root@k0s-w1, ...
```
Steht dort `version: 8.4.x`, ist das alte Modul aus dem Ubuntu-Kernel geladen. Dann hat DKMS nicht gebaut. Prüfe `dkms status`.
]

== LVM darf DRBD-Geräte nicht anfassen

LVM durchsucht beim Start alle Blockgeräte nach Volume-Groups. Liegt auf einem DRBD-Gerät wieder LVM, etwa in einer VM, sieht der Host dieselbe Volume-Group zweimal. Ein Filter verhindert das:

#cmd("k0s-w1")[```bash
sudo sed -i 's|^\(\s*\)# global_filter = .*|\1global_filter = [ "r\|^/dev/drbd\|" ]|' /etc/lvm/lvm.conf
sudo lvmconfig devices/global_filter
```][Ersetzt die auskommentierte Beispielzeile durch einen Filter, der alle `/dev/drbd*` ausschließt. Das gilt für alle vier Nodes.]

#pruefe[
```
global_filter="r|^/dev/drbd|"
```
]

== Eine Falle direkt nach der Installation

#cmd("k0s-w1")[```bash
systemctl is-active linstor-satellite linstor-controller drbd-reactor
```][Prüft, welche Dienste die Pakete gestartet haben.]

#pruefe[
```
active
active
active
```
]

Das Paket startet den Controller sofort, auf *jedem* Node, auf dem es installiert ist. Du hast jetzt drei unabhängige Controller mit je einer leeren Datenbank. Registrierst du einen Node bei einem davon, wissen die anderen nichts davon.

#cmd("k0s-w2")[```bash
sudo systemctl disable --now linstor-controller
```][Dasselbe auf `k0s-w3`. Auf `k0s-w1` bleibt der Controller vorerst aktiv. In Kapitel 6 übernimmt drbd-reactor ihn.]

#falle[
  Zwei aktive LINSTOR-Controller sind kein Ausfallschutz, sondern ein Split-Brain auf Verwaltungsebene. Es darf immer nur einen geben. Nach jeder Paketinstallation auf einem Controller-Kandidaten gilt: `systemctl is-enabled linstor-controller` muss `disabled` melden.
]

== Den Client einrichten

Der Client fragt standardmäßig `localhost`. Auf jedem Node legst du fest, wo der Controller ist:

#datei("/etc/linstor/linstor-client.conf", ```
[global]
controllers=10.10.0.11
```, erklaerung: [Vorerst die Storage-IP von `k0s-w1`. In Kapitel 6 wird daraus die VIP `10.10.0.100`.])

== Nodes registrieren

Ab hier laufen alle `linstor`-Befehle auf einem beliebigen Worker. Das Buch nutzt `k0s-w1`.

#cmd("k0s-w1")[```bash
linstor node create k0s-w1 10.10.0.11 --node-type satellite
linstor node create k0s-w2 10.10.0.12 --node-type satellite
linstor node create k0s-w3 10.10.0.13 --node-type satellite
linstor node create k0s-ctrl 172.16.0.176 --node-type satellite
linstor node list
```][Die IP ist die Standard-Schnittstelle des Nodes. Über sie spricht der Controller mit dem Satellite, und über sie läuft DRBD, solange nichts anderes festgelegt ist. Die Worker bekommen deshalb ihre Storage-IP, die Witness ihre Management-IP.]

#pruefe[
```
│ Node     │ NodeType  │ Addresses                 │ State  │
│ k0s-ctrl │ SATELLITE │ 172.16.0.176:3366 (PLAIN) │ Online │
│ k0s-w1   │ SATELLITE │ 10.10.0.11:3366 (PLAIN)   │ Online │
│ k0s-w2   │ SATELLITE │ 10.10.0.12:3366 (PLAIN)   │ Online │
│ k0s-w3   │ SATELLITE │ 10.10.0.13:3366 (PLAIN)   │ Online │
```
Beim Anlegen meldet jeder Node, welche Speicherarten und Schichten er kann. Wichtig sind `lvm` und die Schichten `drbd` und `writecache`. Die Meldungen zu ZFS und SPDK kannst du ignorieren.
]

== Die Witness über das Management-Netz anbinden

Die Witness sitzt in dieser Architektur an einem dritten Standort, bis zu dem das Storage-Netz nicht reicht. Im Lab hat `k0s-ctrl` deshalb keine Adresse im Storage-Netz. Für eine Verbindung zwischen `k0s-w1` und `k0s-ctrl` würde DRBD aber die Standard-Schnittstelle von `k0s-w1` nehmen, also `10.10.0.11`. Die Witness kann darauf nicht antworten.

Die Lösung ist ein *Pfad*: Für bestimmte Node-Paare legst du fest, über welche Schnittstellen sie sich verbinden.

#cmd("k0s-w1")[```bash
linstor node interface create k0s-w1 mgmt 172.16.0.186
linstor node interface create k0s-w2 mgmt 172.16.0.36
linstor node interface create k0s-w3 mgmt 172.16.0.72
linstor node interface create k0s-ctrl mgmt 172.16.0.176
linstor node-connection path create k0s-w1 k0s-ctrl witness mgmt mgmt
linstor node-connection path create k0s-w2 k0s-ctrl witness mgmt mgmt
linstor node-connection path create k0s-w3 k0s-ctrl witness mgmt mgmt
```][Jeder Node bekommt eine zweite Schnittstelle namens `mgmt`. Die drei Pfade sagen: Zwischen einem Worker und der Witness läuft DRBD über `mgmt` auf beiden Seiten.]

#cmd("k0s-w1")[```bash
linstor node-connection path list k0s-w1 k0s-ctrl
```][Zeigt den Pfad.]

#pruefe[
```
│ Key                    │ Value │
│ Paths/witness/k0s-ctrl │ mgmt  │
│ Paths/witness/k0s-w1   │ mgmt  │
```
Ob DRBD den Pfad wirklich nutzt, siehst du erst an einer Ressource, in Kapitel 6.
]

== Zonen festlegen

Die Server stehen in zwei Brandabschnitten, Zone a und Zone b. Ein Volume soll je ein Replikat in jeder Zone haben. LINSTOR kennt Zonen nicht von sich aus. Du hängst sie als freie Eigenschaft an die Nodes:

#cmd("k0s-w1")[```bash
linstor node set-property k0s-w1 Aux/zone a
linstor node set-property k0s-w2 Aux/zone b
linstor node set-property k0s-w3 Aux/zone a
linstor node list-properties k0s-w2
```][`Aux/` markiert eigene Eigenschaften. LINSTOR wertet sie nicht aus, du kannst sie aber in Platzierungsregeln verwenden (Kapitel 7).]

#pruefe[
```
│ Aux/zone        │ b       │
│ CurStltConnName │ default │
│ NodeUname       │ k0s-w2  │
```
]

#gelernt(
  [LINSTOR auf den Hosts überlebt jeden Ausfall und jedes Update von Kubernetes.],
  [Das PPA hat nur die neueste Version. Feste Versionen kommen aus LINBITs Debian-Repository und werden mit `apt-mark hold` gesichert.],
  [Nach der Installation laufen Controller auf allen Kandidaten. Es darf nur einen geben.],
  [Die Node-IP ist die Standard-Schnittstelle für Satellite-Verkehr und DRBD.],
  [Pfade legen für einzelne Node-Paare ein anderes Netz fest, hier für die Witness.],
  [Zonen sind `Aux/`-Eigenschaften an den Nodes.],
)
