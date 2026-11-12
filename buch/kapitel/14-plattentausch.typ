#import "../lib.typ": *

#kapitel(
  [Betrieb: Eine Datenplatte tauschen],
  ziel: [Du erkennst eine ausgefallene Datenplatte, räumst ihre Reste ab, richtest die Ersatzplatte ein und lässt LINSTOR die Kopien darauf neu aufbauen, ohne dass die Anwendung etwas merkt.],
  zeit: [30 Minuten],
  braucht: [Zugriff auf den Hypervisor, um eine Platte zu entfernen und eine neue einzuhängen],
)

== Den Defekt nachstellen

Im Lab trifft es `k0s-w2`, den einzigen Node in Zone b. Auf ihm liegen Kopien von `linstor_db` und der PostgreSQL-Datenbank, der Primary der Datenbank läuft auf `k0s-w3`.

In Proxmox, bei der VM `k0s-w2`, im laufenden Betrieb:

+ _Hardware_ → die Datenplatte (`scsi1`, 32 GB) → _Detach_. Für das System ist die Platte damit schlagartig weg, wie bei einem Defekt.
+ Die jetzt als „Unused“ markierte Platte → _Remove_.
+ _Add → Hard Disk_, 32 GB, gleicher Bus. Das ist die Ersatzplatte.

== Was der Ausfall auslöst

#cmd("k0s-w2")[```bash
sudo journalctl -k --since "-30min" | grep -E "sdb|drbd1001"
```][Was der Kernel gesehen hat.]

#pruefe[
```
kernel: sd 0:0:0:1: [sdb] Synchronizing SCSI cache
kernel: sd 0:0:0:1: [sdb] Add. Sense: Logical unit not supported
kernel: drbd pvc-55d1f760-.../0 drbd1001: disk( UpToDate -> Failed ) [local-io-error]
kernel: drbd pvc-55d1f760-.../0 drbd1001: Local IO failed in drbd_endio_write_sec_final. Detaching...
```
]

DRBD hat den ersten Schreibfehler bemerkt und die lokale Platte abgehängt. Die Ressource läuft auf `k0s-w2` jetzt *diskless* weiter: Sie ist noch mit den Partnern verbunden, hat aber keine eigenen Daten mehr.

#cmd("k0s-w2")[```bash
sudo drbdadm status pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250
```][Die Sicht von DRBD auf `k0s-w2`.]

#pruefe[
```
pvc-55d1f760-... role:Secondary
  disk:Diskless client:no open:no
  k0s-ctrl role:Secondary
    peer-disk:Diskless peer-client:yes
  k0s-w3 role:Primary
    peer-disk:UpToDate
```
`client:no` heißt: Diese Kopie *sollte* Daten haben, hat sie aber nicht. Eine gewollt disklose Kopie wie auf der Witness zeigt `client:yes`.
]

#cmd("k0s-w3")[```bash
linstor resource list
```][Die Sicht von LINSTOR.]

#pruefe[
```
│ linstor_db       │ k0s-w2   │ DRBD,STORAGE            │ Unused │ Ok    │ Diskless, SkipDisk (R) │ Yes  │
│ pvc-55d1f760-... │ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ Diskless, SkipDisk (R) │ Yes  │
SkipDisk:
  At least one resource has 'DrbdOptions/SkipDisk' enabled. This indicates an IO error on the
  affected resource(s). Remove this property (using 'linstor resource set-property $node $rsc
  DrbdOptions/SkipDisk') to instruct LINSTOR and DRBD to adjust (and recreate if necessary)
  the affected logical volumes again.
```
LINSTOR hat bei jeder betroffenen Ressource `SkipDisk` gesetzt. Damit versucht es nicht ständig, die kaputte Platte wieder anzuhängen. Die Meldung sagt gleich, wie es weitergeht.
]

Die Anwendung hat davon nichts gemerkt. Der Client aus Kapitel 10 meldete in dieser Zeit keinen einzigen Fehler, weil der Primary auf `k0s-w3` liegt und die Kopie dort intakt ist.

#warum[
  Bis die Platte getauscht ist, gibt es von jeder Ressource auf `k0s-w2` nur noch *eine* Kopie mit Daten. Fällt jetzt auch `k0s-w3` aus, sind die Daten weg. Ein Plattendefekt ist deshalb immer dringend, auch wenn alles weiterläuft. `drbd_device_unintentionaldiskless` aus Kapitel 17 meldet genau diesen Zustand.
]

#cmd("k0s-w3")[```bash
linstor storage-pool list -n k0s-w2
```][Wie sieht LINSTOR den Pool der kaputten Platte?]

#pruefe[
```
│ pool_data            │ k0s-w2 │ LVM      │ data     │    27.79 GiB │     30.00 GiB │ True │ Ok │
│ pool_nvme            │ k0s-w2 │ LVM      │ cache    │     1.89 GiB │      2.00 GiB │ True │ Ok │
```
Der Pool steht noch auf `Ok`, mit den Werten von vor dem Ausfall. Verlass dich nicht auf diese Anzeige, sondern auf DRBD.
]

== Die Reste abräumen

Die Ersatzplatte heißt `sdc`, nicht `sdb`. Der Kernel vergibt Namen in der Reihenfolge, in der Geräte erscheinen. Von der alten Platte sind noch Device-Mapper-Geräte übrig:

#cmd("k0s-w2")[```bash
lsblk
sudo dmsetup info -c -o name,open
```][Die Platten und die verbliebenen Device-Mapper-Geräte.]

#pruefe[
```
sdc         32G disk
...
Name                                                              Open
cache-pvc--55d1f760--...cache_00000                                  1
data-linstor_db_00000                                                0
data-pvc--55d1f760--..._00000                                        1
linstor_writecache_pvc-55d1f760-..._00000                            0
```
]

Diese Geräte zeigen auf eine Platte, die es nicht mehr gibt. Die neuen LVs bekommen dieselben Namen und würden mit ihnen kollidieren. Du entfernst sie von oben nach unten, also erst den Writecache, dann die LVs darunter:

#cmd("k0s-w2")[```bash
sudo dmsetup remove linstor_writecache_pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250_00000
sudo dmsetup remove cache-pvc--55d1f760--7f7b--4d71--8a03--0e1e8cd11250.cache_00000
sudo dmsetup remove data-pvc--55d1f760--7f7b--4d71--8a03--0e1e8cd11250_00000
sudo dmsetup remove data-linstor_db_00000
sudo dmsetup ls
```][Danach meldet `dmsetup ls` `No devices found`.]

#falle[
  Entferne nur Geräte, die zu der ausgefallenen Platte gehören. Auf einem Node mit mehreren Platten liegen daneben gesunde Geräte. `lsblk` zeigt, welche Geräte noch an einer vorhandenen Platte hängen.
]

== Die Ersatzplatte einrichten

Genau wie in Kapitel 2, nur mit `sdc`:

#cmd("k0s-w2")[```bash
sudo wipefs -a /dev/sdc
sudo parted -s /dev/sdc mklabel gpt mkpart data 1MiB 30GiB mkpart cache 30GiB 100%
sudo pvcreate /dev/sdc1 /dev/sdc2
sudo vgcreate data /dev/sdc1
sudo vgcreate cache /dev/sdc2
sudo vgs
```][Die Volume-Groups bekommen dieselben Namen wie vorher. Die Storage-Pools in LINSTOR verweisen auf diese Namen und bleiben dadurch unverändert.]

#pruefe[
```
  VG    #PV #LV #SN Attr   VSize   VFree
  cache   1   0   0 wz--n-  <2.00g  <2.00g
  data    1   0   0 wz--n- <30.00g <30.00g
```
]

#hinweis("Gerätenamen", akzent, akzent-hell)[
  Dass die Platte jetzt `sdc` heißt, ist für LVM egal. LVM erkennt seine Physical Volumes an ihrer UUID, nicht am Namen. Nach dem nächsten Neustart kann die Platte auch wieder `sdb` heißen.
]

== Die Kopien neu aufbauen

Jetzt tust du, was LINSTOR in seiner Meldung vorgeschlagen hat:

#cmd("k0s-w3")[```bash
linstor resource set-property k0s-w2 linstor_db DrbdOptions/SkipDisk
linstor resource set-property k0s-w2 pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250 DrbdOptions/SkipDisk
```][Ohne Wert gesetzt, wird die Eigenschaft gelöscht. LINSTOR legt daraufhin die fehlenden LVs neu an, baut den Writecache auf und hängt die Platte wieder unter DRBD. DRBD synchronisiert die Daten von der Gegenseite.]

Eine halbe Minute später:

#cmd("k0s-w3")[```bash
linstor resource list
linstor resource list --faulty
```][Der Zustand danach.]

#pruefe[
```
│ linstor_db       │ k0s-w2   │ DRBD,STORAGE            │ Unused │ Ok    │ UpToDate │ Yes  │
│ pvc-55d1f760-... │ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
```
`--faulty` ist leer.
]

#cmd("k0s-w2")[```bash
lsblk /dev/sdc
```][Der neu aufgebaute Gerätestapel.]

#pruefe[
```
sdc                                          32G  disk
├─sdc1                                       30G  part
│ ├─data-linstor_db_00000                   204M  lvm
│ │ └─drbd1000                            203.9M  disk
│ └─data-pvc--55d1f760--..._00000             2G  lvm
│   └─linstor_writecache_pvc-55d1f760-..._00000  2G  dm
│     └─drbd1001                              2G  disk
└─sdc2                                        2G  part
  └─cache-pvc--55d1f760--...cache_00000     104M  lvm
    └─linstor_writecache_pvc-55d1f760-..._00000  2G  dm
```
Derselbe Aufbau wie in Kapitel 7, auf der neuen Platte. Der Cache hat 104 MB, 5 % von 2 GB.
]

#gelernt(
  [Bei einem Plattendefekt hängt DRBD die Platte ab und läuft diskless weiter. Die Anwendung merkt nichts.],
  [LINSTOR setzt `SkipDisk` und zeigt `Diskless, SkipDisk (R)`.],
  [Bis zum Tausch gibt es nur eine Kopie. Das ist dringend, auch wenn alles läuft.],
  [Alte Device-Mapper-Geräte von oben nach unten mit `dmsetup remove` abräumen.],
  [Volume-Groups mit denselben Namen anlegen, dann `SkipDisk` löschen. LINSTOR baut alles neu auf.],
)
