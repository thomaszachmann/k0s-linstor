#import "../lib.typ": *

#kapitel(
  [Storage-Pools, Writecache und Zonen],
  ziel: [Zwei Storage-Pools auf jedem Worker, eine Vorlage für replizierte Volumes mit Writecache und eine Platzierung, die je ein Replikat pro Zone erzwingt.],
  zeit: [30 Minuten],
  braucht: [Die Volume-Groups aus Kapitel 2, die Nodes aus Kapitel 5],
)

== Storage-Pools anlegen

Ein Storage-Pool sagt LINSTOR, wo es auf einem Node Speicher anlegen darf. Jeder Worker bekommt zwei:

#cmd("k0s-w1")[```bash
linstor storage-pool create lvm k0s-w1 pool_data data
linstor storage-pool create lvm k0s-w2 pool_data data
linstor storage-pool create lvm k0s-w3 pool_data data
linstor storage-pool create lvm k0s-w1 pool_nvme cache
linstor storage-pool create lvm k0s-w2 pool_nvme cache
linstor storage-pool create lvm k0s-w3 pool_nvme cache
linstor storage-pool list
```][`lvm` ist der Treiber, `pool_data` der Name in LINSTOR, `data` die Volume-Group auf dem Node. Gleiche Pool-Namen auf allen Nodes sind wichtig: Platzierungsregeln verweisen nur auf den Namen.]

#pruefe[
```
│ StoragePool          │ Node     │ Driver   │ PoolName │ FreeCapacity │ TotalCapacity │
│ DfltDisklessStorPool │ k0s-ctrl │ DISKLESS │          │              │               │
│ ...                                                                                 │
│ pool_data            │ k0s-w1   │ LVM      │ data     │    30.00 GiB │     30.00 GiB │
│ pool_data            │ k0s-w2   │ LVM      │ data     │    30.00 GiB │     30.00 GiB │
│ pool_data            │ k0s-w3   │ LVM      │ data     │    30.00 GiB │     30.00 GiB │
│ pool_nvme            │ k0s-w1   │ LVM      │ cache    │     2.00 GiB │      2.00 GiB │
│ pool_nvme            │ k0s-w2   │ LVM      │ cache    │     2.00 GiB │      2.00 GiB │
│ pool_nvme            │ k0s-w3   │ LVM      │ cache    │     2.00 GiB │      2.00 GiB │
```
`DfltDisklessStorPool` legt LINSTOR auf jedem Node selbst an. Er steht für Kopien ohne Daten.
]

#hinweis("LVM oder LVM-thin?", akzent, akzent-hell)[
  `lvm` reserviert den vollen Platz eines Volumes sofort. `lvmthin` reserviert nur, was geschrieben wird, und kann Snapshots. Dieses Buch nutzt klassisches LVM: berechenbar, kein Überbuchen, kein voller Thin-Pool, der alle Volumes gleichzeitig einfriert. Der Preis sind fehlende Snapshots, darum geht es in Kapitel 13.
]

== Was ein Writecache ist

`dm-writecache` ist eine Funktion des Linux-Kernels. Schreibvorgänge landen zuerst auf dem schnellen Gerät und werden im Hintergrund auf das langsame übertragen. Lesen bleibt beim langsamen Gerät. LINSTOR baut das als eigene Schicht zwischen DRBD und LVM ein:

#tabelle(
  (auto, 1fr),
  ([Schicht], [Aufgabe]),
  [DRBD], [Repliziert jeden Block auf den zweiten Node.],
  [WRITECACHE], [Puffert Schreibvorgänge auf `pool_nvme`.],
  [STORAGE], [Das logische Volume in `pool_data`.],
)

`Writecache/Size` legt fest, wie groß der Cache je Volume ist. `5%` bedeutet: Ein 2-GB-Volume bekommt etwa 100 MB Cache.

#warum[
  Der Cache sitzt *unter* DRBD. DRBD bestätigt einen Schreibvorgang erst, wenn beide Nodes ihn haben. Mit Writecache heißt „haben“: auf der NVMe des jeweiligen Nodes. Die langsame Platte bremst damit nicht mehr jeden Schreibvorgang. Was im Cache steht, ist trotzdem auf beiden Seiten sicher.
]

== Die Vorlage rg-k8s

#cmd("k0s-w1")[```bash
linstor resource-group create rg-k8s --storage-pool pool_data --place-count 2 \
  --replicas-on-different zone --layer-list drbd,writecache,storage
linstor resource-group set-property rg-k8s Writecache/PoolName pool_nvme
linstor resource-group set-property rg-k8s Writecache/Size 5%
linstor resource-group drbd-options --quorum=majority --on-no-quorum=suspend-io \
  --on-suspended-primary-outdated=force-secondary rg-k8s
linstor volume-group create rg-k8s
```][Zwei Replikate in `pool_data`, auf Nodes mit unterschiedlichem Wert für `Aux/zone`, mit Writecache aus `pool_nvme`.]

#tabelle(
  (auto, 1fr),
  ([Einstellung], [Wirkung]),
  [`--place-count 2`], [Zwei Kopien mit Daten.],
  [`--replicas-on-different zone`], [Nie zwei Kopien in derselben Zone. Der Client ergänzt `Aux/` selbst.],
  [`on-no-quorum=suspend-io`], [Verliert ein Primary das Quorum, hält DRBD alle Schreibvorgänge an, statt Fehler zu liefern. Die Anwendung hängt, statt ihr Dateisystem zu verlieren. Kommt das Quorum zurück, läuft sie weiter.],
)

#hinweis("Anders als bei linstor_db", akzent, akzent-hell)[
  Für `linstor_db` gilt `io-error`, damit drbd-reactor sofort umschalten kann. Für Anwendungsdaten gilt `suspend-io`: Ein kurzer Netzaussetzer soll keine Datenbank zerstören. Kapitel 11 zeigt beide Verhaltensweisen live.
]

== Ausprobieren

#cmd("k0s-w1")[```bash
linstor resource-group spawn-resources rg-k8s test1 1G
linstor resource list -r test1
```][Erzeugt ein Test-Volume aus der Vorlage.]

#pruefe[
```
│ ResourceName │ Node     │ Layers                  │ Usage  │ Conns │              State │ Vote │
│ test1        │ k0s-ctrl │ DRBD,STORAGE            │ Unused │ Ok    │           Diskless │ Yes  │
│ test1        │ k0s-w1   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │           UpToDate │ Yes  │
│ test1        │ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ SyncTarget(62.30%) │ Yes  │
```
Ein Replikat in Zone a (`k0s-w1`), eines in Zone b (`k0s-w2`). `k0s-w3` liegt ebenfalls in Zone a und bleibt deshalb leer. Auf der Witness hat LINSTOR von sich aus einen *Tiebreaker* angelegt, eine Kopie ohne Daten, die beim Quorum mitstimmt. Mit nur zwei Stimmen gäbe es bei einer Netztrennung keine Mehrheit.
]

Wie das auf der Platte aussieht, zeigt `lsblk` auf `k0s-w1`:

#cmd("k0s-w1")[```bash
lsblk /dev/sdb
sudo dmsetup table | grep writecache
```][Der Gerätestapel des Test-Volumes.]

#pruefe[
```
sdb                                    8:16    0    32G  0 disk
├─sdb1                                 8:17    0    30G  0 part
│ ├─data-linstor_db_00000            252:0     0   204M  0 lvm
│ │ └─drbd1000                       147:1000  0 203.9M  0 disk
│ └─data-test1_00000                 252:1     0     1G  0 lvm
│   └─linstor_writecache_test1_00000 252:3     0     1G  0 dm
│     └─drbd1001                     147:1001  0     1G  0 disk
└─sdb2                                 8:18    0     2G  0 part
  └─cache-test1.cache_00000          252:2     0    52M  0 lvm
    └─linstor_writecache_test1_00000 252:3     0     1G  0 dm
      └─drbd1001                     147:1001  0     1G  0 disk
linstor_writecache_test1_00000: 0 2105344 writecache s 252:1 252:2 4096 0
```
`linstor_writecache_test1_00000` setzt sich aus dem Daten-LV (`252:1`) und dem 52-MB-Cache-LV (`252:2`) zusammen. Darauf sitzt `drbd1001`. Das sind 5 % von 1 GB, aufgerundet auf LVM-Blöcke.
]

#cmd("k0s-w1")[```bash
linstor resource-definition delete test1
```][Räumt das Test-Volume wieder ab.]

#falle[
  Die Vorlage `rg-k8s` ist für LINSTOR selbst gedacht. Sobald der CSI-Treiber sie benutzt, überschreibt er ihre Einstellungen mit den Parametern der StorageClass. Was dort fehlt, setzt er auf seine Standardwerte. Kapitel 8 zeigt, wie das im Lab aus zwei Replikaten eines gemacht hat.
]

#gelernt(
  [Storage-Pools verbinden einen Namen in LINSTOR mit einer Volume-Group auf dem Node.],
  [Klassisches LVM ist berechenbar, kann aber keine Snapshots.],
  [Die Writecache-Schicht puffert Schreibvorgänge unter DRBD auf schnellem Speicher.],
  [`--replicas-on-different zone` verteilt Replikate über Zonen.],
  [LINSTOR legt Tiebreaker auf der Witness selbst an.],
)
