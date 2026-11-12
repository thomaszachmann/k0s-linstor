#import "../lib.typ": *

= Anhang

== Befehle für den Alltag

#tabelle(
  (auto, 1fr),
  ([Befehl], [Wofür]),
  [`drbdadm status`], [Zustand aller DRBD-Ressourcen auf diesem Node],
  [`drbdsetup status --verbose --statistics <res>`], [Quorum, Out-of-Sync, Backing-Device],
  [`linstor node list`], [Sind alle Satellites online?],
  [`linstor resource list --faulty`], [Nur Ressourcen mit Problemen],
  [`linstor storage-pool list`], [Freier Platz je Pool und Node],
  [`linstor error-reports list`], [Fehlerberichte des Controllers],
  [`drbd-reactorctl status linstor_db`], [Wo läuft der Controller?],
  [`drbd-reactorctl evict linstor_db`], [Controller geplant abgeben],
  [`linstor controller list-properties`], [Globale Einstellungen, auch die des Operators],
  [`k0s status`], [Rolle und Version des lokalen k0s],
  [`k0s sysinfo`], [Voraussetzungen des Hosts prüfen],
  [`journalctl -u k0sworker` / `-u linstor-satellite`], [Logs des Nodes],
)

== Fehlerbilder

#tabelle(
  (auto, 1fr, auto),
  ([Du siehst], [Wahrscheinliche Ursache], [Kapitel]),
  [CSI-Pods `Pending`, `didn't match Pod's node affinity/selector`], [`nodeSelector` des LinstorCluster gilt auch für CSI], [8],
  [CSI-Node `Init:0/1`, `/var/lib/kubelet/plugins_registry is not a directory`], [kubelet-Pfad von k0s], [8],
  [CSI-Node-Pods werden alle paar Sekunden neu erzeugt], [`Aux/topology/linbit.com/hostname` fehlt am LINSTOR-Node], [8],
  [Volume hat 1 Replikat statt 2, kein Writecache], [StorageClass ohne vollständige Parameter überschreibt die Resource-Group], [8],
  [CSI `CrashLoopBackOff`, `REST API 1.27.0 is not supported`], [CSI 1.13 gegen LINSTOR 1.33], [15],
  [`Cannot grow the volume definition ... StorPool: pool_nvme`], [Zuwachs größer als freier Cache-Pool], [12],
  [PVC größer, `df` im Pod unverändert], [Writecache-Gerät nicht mitgewachsen], [12],
  [`Storage driver 'LVM' does not support snapshots`], [LINSTOR 1.33 mit klassischem LVM], [13],
  [Node `OFFLINE` direkt nach Paket-Update], [Satellite und Controller haben verschiedene Versionen], [15],
  [`Connection refused` von der VIP], [Controller startet gerade, Failover läuft], [6, 10],
  [`connection:StandAlone`], [Split-Brain], [11],
  [`suspended:quorum`, Anwendung hängt], [Primary ohne Mehrheit], [11],
  [I/O-Fehler, `force-io-failures:yes`], [Veralteter Primary wurde abgesetzt], [11],
  [Pod hängt in `Terminating` auf `NotReady`-Node], [Node ist aus, Out-of-Service-Taint fehlt], [10],
  [Keine Pods auf einem reparierten Node], [Out-of-Service-Taint noch gesetzt], [10],
  [`driver name linstor.csi.linbit.com not found`], [CSI-Node nach Neustart noch nicht registriert], [10],
  [Zwei LINSTOR-Controller antworten unterschiedlich], [`linstor-controller` nach Paketinstallation auf mehreren Nodes aktiv], [5],
)

== Ports

#tabelle(
  (auto, auto, 1fr),
  ([Port], [Dienst], [Netz]),
  [3366], [LINSTOR-Satellite], [Storage (Worker), Management (Witness)],
  [3370], [LINSTOR-Controller REST und Metriken], [Storage, über die VIP],
  [7000 und folgende], [DRBD, je Ressource ein Port], [Storage, zur Witness Management],
  [9942], [drbd-reactor Metriken], [jeder Node],
  [6443, 9443, 8132], [k0s API, Join, konnectivity], [Management],
  [8333], [SeaweedFS S3 auf `k0s-ctrl`], [Management],
)

== Quellen

- k0s-Dokumentation: `docs.k0sproject.io`
- LINSTOR User Guide: `linbit.com/drbd-user-guide/linstor-guide-1_0-en/`, Abschnitte „Creating a highly available LINSTOR cluster“, „Auto-evict“, „Backup and restore database“
- DRBD 9 User Guide: `linbit.com/drbd-user-guide/drbd-guide-9_0-en/`, Abschnitte zu Quorum und drbd-reactor
- Piraeus-Operator: `github.com/piraeusdatastore/piraeus-operator`, `docs/how-to/external-controller.md` und `docs/how-to/k0s.md`
- Velero: `velero.io/docs`, File System Backup
