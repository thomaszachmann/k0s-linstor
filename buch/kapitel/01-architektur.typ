#import "../lib.typ": *

#kapitel(
  [Was du aufbaust und warum so],
  ziel: [Du hast das Gesamtbild vor Augen: welche Software auf welcher VM läuft, über welches Netz welche Daten fließen und in welcher Reihenfolge das Buch alles aufbaut.],
  zeit: [15 Minuten Lesen],
)

== Das Muster

Dieses Buch baut ein Architekturmuster auf, wie es in Rechenzentren mit eigener Hardware verbreitet ist. Kubernetes kommt von k0s, Block-Speicher von LINSTOR und DRBD. Die Besonderheiten dieses Musters bestimmen jedes Kapitel:

- *LINSTOR läuft außerhalb von Kubernetes*, als Pakete auf den Hosts, gestartet von systemd. Kubernetes bekommt nur den CSI-Treiber.
- *Ein aktiver LINSTOR-Controller*, dessen Datenbank selbst auf DRBD liegt. drbd-reactor schwenkt ihn samt virtueller IP auf einen anderen Host, wenn der aktive ausfällt.
- *Zwei Zonen und eine Witness*: Jedes Volume hat eine Kopie in Zone a und eine in Zone b. Eine Witness ohne Daten an einem dritten Standort entscheidet bei Netzproblemen, wer die Mehrheit hat.
- *Ein eigenes Storage-Netz* für die Replikation. Die Witness erreicht es nicht und spricht über das Management-Netz.
- *Klassisches LVM* mit einem schnellen Writecache vor langsamen Platten.

== Was läuft wo

#block(width: 100%, fill: code-bg, radius: 3pt, inset: 10pt)[
#set text(font: mono, size: 7.4pt)
```
                Management-Netz 172.16.0.0/24  (SSH, Kubernetes-API, Pods)
  ──────┬──────────────────────┬──────────────────────┬──────────────────────┬─────
        │                      │                      │                      │
 ┌──────┴───────┐       ┌──────┴───────┐       ┌──────┴───────┐       ┌──────┴───────┐
 │  k0s-ctrl    │       │  k0s-w1      │       │  k0s-w2      │       │  k0s-w3      │
 │  .176        │       │  .186        │       │  .36         │       │  .72         │
 │              │       │  Zone a      │       │  Zone b      │       │  Zone a      │
 │ k0s-Control- │       │ k0s-Worker   │       │ k0s-Worker   │       │ k0s-Worker   │
 │  plane       │       │ CSI-Node     │       │ CSI-Node     │       │ CSI-Node     │
 │              │       │              │       │              │       │              │
 │ LINSTOR-     │       │ Satellite    │       │ Satellite    │       │ Satellite    │
 │  Satellite   │       │ Controller*  │       │ Controller*  │       │ Controller*  │
 │ = Witness    │       │ drbd-reactor │       │ drbd-reactor │       │ drbd-reactor │
 │ (diskless)   │       │              │       │              │       │              │
 │ S3-Backup    │       │ sdb: data    │       │ sdb: data    │       │ sdb: data    │
 │              │       │      cache   │       │      cache   │       │      cache   │
 └──────────────┘       └──────┬───────┘       └──────┬───────┘       └──────┬───────┘
                               │ .11                  │ .12                  │ .13
  ─────────────────────────────┴──────────────────────┴──────────────────────┴─────
                Storage-Netz 10.10.0.0/24  (DRBD-Replikation, VIP .100)

  * Controller läuft immer nur auf einem der drei, dort wo linstor_db Primary ist.
```
]

#tabelle(
  (auto, 1fr),
  ([Verbindung], [Netz]),
  [kubectl, k0sctl, SSH vom Mac], [Management],
  [DRBD zwischen den Workern], [Storage],
  [DRBD zwischen Worker und Witness], [Management, über eigene Pfade (Kapitel 5)],
  [Controller zu den Satellites der Worker], [Storage],
  [Controller zur Witness], [Management],
  [CSI-Treiber zum Controller], [Storage, über die VIP `10.10.0.100`],
  [Velero zum S3-Speicher], [Management],
)

== Ein Schreibvorgang von der Datenbank bis zur Platte

Wenn PostgreSQL auf `k0s-w1` einen Block schreibt:

+ Das Dateisystem gibt den Block an `/dev/drbd1001`.
+ DRBD schreibt ihn in die Writecache-Schicht darunter und schickt ihn gleichzeitig über das Storage-Netz an `k0s-w2`.
+ Auf beiden Nodes landet der Block zuerst im schnellen Cache-Volume und wird im Hintergrund auf das Daten-Volume übertragen.
+ Erst wenn *beide* Nodes den Block bestätigt haben, meldet DRBD der Datenbank: geschrieben.

Die Witness bekommt keine Daten. Sie ist nur mit beiden verbunden und zählt beim Quorum mit.

== Versionen

#tabelle(
  (auto, auto, auto),
  ([Komponente], [Aufbau], [nach Kapitel 15]),
  [Ubuntu], [24.04.5, Kernel 6.8], [unverändert],
  [k0s], [v1.36.6+k0s.0], [v1.37.2+k0s.1],
  [k0sctl], [v0.33.1], [unverändert],
  [DRBD], [9.3.4 (DKMS), drbd-utils 9.36.0~rc.1], [unverändert],
  [LINSTOR], [1.33.3], [1.35.3],
  [drbd-reactor], [1.12.0], [unverändert],
  [Piraeus-Operator], [2.12.0, Chart `linstor-cluster` 1.2.0], [unverändert],
  [linstor-csi], [v1.12.0], [v1.13.1],
  [Velero], [1.18.2 (Chart 12.2.4), AWS-Plugin 1.14.4], [–],
)

== Der Bauplan

#tabelle(
  (auto, 1fr, auto),
  ([Kapitel], [Ergebnis], [So prüfst du es]),
  [2], [VMs mit Storage-Netz und Volume-Groups], [`ip route get`, `vgs`],
  [3, 4], [k0s-Cluster, Zonen als Node-Labels], [`kubectl get nodes -L topology.kubernetes.io/zone`],
  [5], [LINSTOR auf allen Hosts, Witness-Pfade, Zonen], [`linstor node list`],
  [6], [Controller-HA mit VIP], [`drbd-reactorctl status`, `evict`],
  [7], [Pools, Writecache, Platzierung], [`linstor resource list`, `lsblk`],
  [8], [CSI, StorageClass, PostgreSQL], [Pod-Umzug ohne Datenverlust],
  [9], [Zustände lesen können], [`drbdadm status`],
  [10–15], [Betrieb: Ausfälle, Quorum, Kapazität, Backup, Plattentausch, Updates], [Messungen im Lab],
  [16], [Dasselbe mit Ansible], [`changed=0`],
  [17], [Metriken und Alarme], [`promtool test rules`],
  [18], [Vom Lab zur Produktion], [–],
)

#gelernt(
  [LINSTOR läuft auf den Hosts, Kubernetes nutzt es nur über CSI.],
  [Zwei Netze: Management für Verwaltung und Witness, Storage für Replikation und VIP.],
  [Ein Schreibvorgang ist erst fertig, wenn beide Kopien ihn haben.],
)
