#import "../lib.typ": *

#kapitel(
  [Vier VMs vorbereiten],
  ziel: [Vier Ubuntu-VMs sind per SSH erreichbar, haben ein eigenes Storage-Netz und auf den drei Workern zwei Volume-Groups: eine große für Daten und eine kleine als Schreibcache.],
  zeit: [30 Minuten],
  braucht: [Vier Ubuntu-24.04-VMs auf Proxmox, je Worker eine leere zweite Platte, eine zweite Netzwerkkarte an einer internen Bridge],
)

== Was du aufbaust

#tabelle(
  (auto, auto, auto, auto, auto),
  ([VM], [Management-IP], [Storage-IP], [Rolle], [Zone]),
  [`k0s-ctrl`], [`172.16.0.176`], [–], [k0s-Controller, LINSTOR-Witness], [–],
  [`k0s-w1`], [`172.16.0.186`], [`10.10.0.11`], [Worker, Storage], [a],
  [`k0s-w2`], [`172.16.0.36`], [`10.10.0.12`], [Worker, Storage], [b],
  [`k0s-w3`], [`172.16.0.72`], [`10.10.0.13`], [Worker, Storage], [a],
)

Über `eth0` laufen SSH, die Kubernetes-API und der Verkehr der Pods. Über `ens19` läuft nur die DRBD-Replikation zwischen den Workern. In einer echten Umgebung ist das ein eigenes VLAN auf eigenen Ports, im Lab eine Proxmox-Bridge ohne physischen Port.

Die Witness `k0s-ctrl` bekommt bewusst keine Adresse im Storage-Netz. Sie steht für einen Server an einem dritten Standort, bis zu dem das Storage-Netz nicht reicht. Sie spricht über das Management-Netz mit den anderen, wie das in Kapitel 5 eingerichtet wird.

#warum[
  DRBD schreibt jeden Block synchron auf ein zweites System. Die Latenz des Netzes geht direkt in jede Schreiboperation der Datenbank ein. Teilt sich die Replikation die Leitung mit Image-Pulls und Backups, wird jede Schreiblast unberechenbar. Ein eigenes Netz trennt diese Lasten, und du siehst im Fehlerfall sofort, welches Netz gemeint ist.
]

== Die interne Bridge in Proxmox

In der Proxmox-Oberfläche unter _Datacenter → pve → System → Network → Create → Linux Bridge_:

- Name `vmbr1`
- IPv4/CIDR leer lassen, Bridge ports leer lassen
- _Create_, dann _Apply Configuration_

Danach bekommen die drei Worker unter _Hardware → Add → Network Device_ eine zweite Karte an `vmbr1`, Modell VirtIO, Firewall aus. Die drei Worker bekommen außerdem unter _Hardware → Add → Hard Disk_ eine zweite Platte.

#falle[
  Eine Bridge ohne Port verbindet nur VMs auf demselben Proxmox-Host. Liegen die VMs auf mehreren Hosts, brauchst du ein VLAN auf der physischen Bridge oder ein SDN-Netz.
]

== SSH vom Mac

Alle Befehle mit dem Etikett „Mac“ laufen auf deinem Rechner. Damit du nicht jedes Mal IP, Benutzer und Schlüssel tippen musst, bekommen die VMs Kurznamen:

#datei("~/.ssh/config (Ausschnitt)", ```
Host k0s-ctrl
    HostName 172.16.0.176
Host k0s-w1
    HostName 172.16.0.186
Host k0s-w2
    HostName 172.16.0.36
Host k0s-w3
    HostName 172.16.0.72
Host k0s-ctrl k0s-w1 k0s-w2 k0s-w3
    User ubuntu
    IdentityFile ~/.ssh/homelab
    IdentitiesOnly yes
```, erklaerung: [`IdentitiesOnly` sorgt dafür, dass SSH nur diesen Schlüssel anbietet. Mit vielen Schlüsseln im Agent lehnt der Server sonst nach zu vielen Versuchen ab.])

#cmd("Mac")[```bash
ssh k0s-w1 'hostname; ip -br link; lsblk'
```][Zeigt Namen, Netzwerkkarten und Platten von `k0s-w1`.]

#pruefe[
```
k0s-w1
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
eth0             UP             bc:24:11:bc:2e:3b <BROADCAST,MULTICAST,UP,LOWER_UP>
ens19            DOWN           bc:24:11:ba:60:15 <BROADCAST,MULTICAST>
NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda       8:0    0   30G  0 disk
├─sda1    8:1    0   29G  0 part /
...
sdb       8:16   0   32G  0 disk
```
`ens19` ist da, aber noch `DOWN` und ohne Adresse. `sdb` ist leer, ohne Partitionen. Wiederhole den Befehl für `k0s-w2` und `k0s-w3`.
]

== Das Storage-Netz einrichten

Ubuntu konfiguriert Netze mit netplan. Die vorhandene Datei `50-cloud-init.yaml` lässt du in Ruhe und legst eine zweite Datei nur für `ens19` an.

#datei("lab/netplan/60-storage-k0s-w1.yaml", ```yaml
# Storage-Netz für DRBD (vmbr1 auf Proxmox, ohne Gateway)
network:
  version: 2
  ethernets:
    ens19:
      addresses: [10.10.0.11/24]
      mtu: 1500
```, erklaerung: [Kein Gateway und kein DNS: Das Storage-Netz führt nirgendwohin außer zu den anderen Nodes. Die Dateien für die anderen Nodes unterscheiden sich nur in der Adresse.])

#cmd("Mac")[```bash
scp lab/netplan/60-storage-k0s-w1.yaml k0s-w1:/tmp/60-storage.yaml
ssh k0s-w1 'sudo install -m 600 /tmp/60-storage.yaml /etc/netplan/60-storage.yaml'
ssh k0s-w1 'sudo netplan apply'
ssh k0s-w1 'ip -br addr show ens19'
```][`install -m 600` setzt gleich die Rechte, die netplan verlangt. Mit lesbaren Rechten für alle warnt netplan bei jedem Aufruf.]

#pruefe[
```
ens19            UP             10.10.0.11/24 fe80::be24:11ff:feba:6015/64
```
]

Dasselbe machst du für `k0s-w2` (`10.10.0.12`) und `k0s-w3` (`10.10.0.13`) mit der jeweiligen Datei aus `lab/netplan/`. `k0s-ctrl` bleibt ohne Adresse auf `ens19`.

#cmd("Mac")[```bash
ssh k0s-w1 'ping -c2 -q 10.10.0.12'
ssh k0s-w1 'ip route get 10.10.0.12'
```][Der erste Befehl prüft, ob `k0s-w2` erreichbar ist. Der zweite zeigt, über welche Karte der Weg führt.]

#pruefe[
```
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
10.10.0.12 dev ens19 src 10.10.0.11 uid 1000
```
`dev ens19` ist die wichtige Stelle. Stünde dort `eth0`, liefe die Replikation später über das falsche Netz.
]

== Platten für LINSTOR vorbereiten

In der Architektur dieses Buchs liegen die Daten auf großen, langsamen Festplatten. Davor sitzt ein kleiner, schneller NVMe-Bereich als Schreibcache. Im Lab gibt es nur eine virtuelle Platte pro Worker, also teilst du sie in zwei Partitionen und tust so, als wären es zwei Geräte:

#tabelle(
  (auto, auto, auto, auto),
  ([Partition], [Größe], [Volume-Group], [steht für]),
  [`/dev/sdb1`], [30 GB], [`data`], [HDD mit den Daten],
  [`/dev/sdb2`], [2 GB], [`cache`], [NVMe als Schreibcache],
)

#hinweis("Nur im Lab", warn, warn-hell)[
  Zwei Partitionen auf derselben virtuellen Platte sind gleich schnell. Der Cache bringt im Lab also keine Geschwindigkeit. Du lernst trotzdem den kompletten Aufbau und alle Befehle, und genau darum geht es.
]

#cmd("k0s-w1")[```bash
sudo apt-get install -y lvm2 thin-provisioning-tools
sudo wipefs -a /dev/sdb
sudo parted -s /dev/sdb mklabel gpt mkpart data 1MiB 30GiB mkpart cache 30GiB 100%
sudo pvcreate /dev/sdb1 /dev/sdb2
sudo vgcreate data /dev/sdb1
sudo vgcreate cache /dev/sdb2
sudo vgs
```][`wipefs` entfernt alte Signaturen, falls die Platte vorher benutzt war. `parted` legt die zwei Partitionen an. `pvcreate` macht sie zu physischen LVM-Volumes, `vgcreate` fasst jede in eine eigene Volume-Group. LINSTOR legt später darin für jedes Kubernetes-Volume ein logisches Volume an.]

#pruefe[
```
  VG    #PV #LV #SN Attr   VSize   VFree
  cache   1   0   0 wz--n-  <2.00g  <2.00g
  data    1   0   0 wz--n- <30.00g <30.00g
```
]

Wiederhole das auf `k0s-w2` und `k0s-w3`. Auf `k0s-ctrl` legst du keine Volume-Groups an, er speichert später keine Daten.

#falle[
  `wipefs -a` löscht ohne Rückfrage. Prüfe vorher mit `lsblk`, dass `sdb` wirklich die leere Zusatzplatte ist und nicht die Systemplatte.
]

#gelernt(
  [Replikation bekommt ein eigenes Netz, weil ihre Latenz in jeden Schreibvorgang eingeht.],
  [Eine zusätzliche netplan-Datei konfiguriert nur `ens19` und lässt die Cloud-Init-Konfiguration unberührt.],
  [`ip route get` zeigt, über welche Karte ein Ziel erreicht wird.],
  [Zwei Volume-Groups bilden Datenplatte und Cache-Platte nach.],
)
