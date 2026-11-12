#import "../lib.typ": *

#kapitel(
  [Betrieb: Updates von LINSTOR, CSI und k0s],
  ziel: [LINSTOR von 1.33.3 auf 1.35.3, den CSI-Treiber von 1.12 auf 1.13 und k0s von 1.36.6 auf 1.37.2, in der richtigen Reihenfolge und ohne die Datenbank zu verlieren. Dazu der Blick darauf, was dabei schiefgehen kann.],
  zeit: [90 Minuten],
  braucht: [Den Cluster aus den vorigen Kapiteln mit Velero aus Kapitel 13],
)

== Die Abhängigkeit

Der CSI-Treiber spricht mit dem LINSTOR-Controller über dessen REST-API. Jede CSI-Version verlangt eine Mindestversion dieser API:

#tabelle(
  (auto, auto, auto),
  ([LINSTOR], [REST-API], [passender CSI-Treiber]),
  [1.33.3], [1.27.0], [bis 1.12.x],
  [1.35.3], [1.29.1], [1.13.x],
)

Daraus folgt die Reihenfolge: *erst LINSTOR, dann CSI.* Umgekehrt geht es nicht, wie der nächste Abschnitt zeigt.

== Die falsche Reihenfolge

Was passiert, wenn jemand den Pin auf CSI 1.12 entfernt, bevor LINSTOR aktualisiert ist?

#cmd("Mac")[```bash
helm upgrade linstor-cluster piraeus-charts/linstor-cluster --version 1.2.0 \
  -n piraeus-datastore -f werte-mit-csi-1.13.1.yaml
kubectl -n piraeus-datastore get pods
kubectl -n piraeus-datastore logs deploy/linstor-csi-controller -c linstor-csi --tail=1
```][Die Werte aus Kapitel 8, nur mit `piraeus-csi:v1.13.1` statt `v1.12.0`.]

#pruefe[
```
linstor-csi-controller-6c9bc687dd-bhsv5   5/6   CrashLoopBackOff   11 (8s ago)   70s
linstor-csi-node-647g6                    2/3   CrashLoopBackOff   5 (6s ago)    66s
...
level=fatal msg="LINSTOR 1.33.3 (REST API 1.27.0) is not supported: the driver requires
  REST API 1.29 or newer in the 1.x series, shipped with LINSTOR 1.35"
```
]

Die Meldung ist eindeutig. Die laufende Datenbank war davon nicht betroffen: Gemountete Volumes brauchen den Treiber nicht mehr. Neue PVCs, Mounts nach einem Pod-Neustart und Vergrößerungen hätten aber nicht funktioniert. Zurück auf 1.12 mit den alten Werten, und alles läuft wieder.

#falle[
  Das ist eine typische Lage: Der Operator 2.12 bringt CSI 1.13 mit, und nur ein Pin hält den Treiber auf 1.12. Wer den Pin bei einem Aufräumen der Helm-Werte entfernt, legt das Anlegen neuer Volumes still. Der Pin gehört kommentiert, und er darf erst nach dem LINSTOR-Update fallen.
]

== Vorbereitung

#cmd("Mac")[```bash
velero -n velero backup create vor-linstor-update --include-namespaces demo --wait
```][Eine frische Sicherung der Anwendungsdaten. Das LINSTOR-Update selbst fasst keine Daten an, aber wer ein Update ohne aktuelle Sicherung beginnt, hat Glück oder Pech.]

#cmd("k0s-w1")[```bash
sudo drbd-reactorctl status linstor_db | head -2
linstor controller version
```][Wo läuft der Controller, und welche Version hat er?]

#pruefe[
```
Promoter: Resource linstor_db currently active on node 'k0s-w2'
linstor controller 1.33.3; GIT-hash: 1ff3a1ea5cb5c77100265ec442bb9a492b225145
```
]

== LINSTOR aktualisieren

Controller und Satellites müssen dieselbe Version haben. Während des Updates gibt es deshalb eine Phase, in der aktualisierte Satellites als `OFFLINE` erscheinen. DRBD läuft davon unberührt weiter, nur der Controller kann diese Nodes kurz nicht steuern.

#hinweis("Reihenfolge", akzent, akzent-hell)[
  + Die Nodes, auf denen der Controller *nicht* läuft
  + Die Witness
  + Den Node mit dem aktiven Controller, nachdem er den Controller abgegeben hat
]

Auf `k0s-w1`, ohne aktiven Controller:

#cmd("k0s-w1")[```bash
V=1.35.3-1ppa1~noble1
sudo apt-mark unhold linstor-common linstor-satellite linstor-controller
sudo apt-get install -y linstor-common=$V linstor-satellite=$V linstor-controller=$V
sudo apt-mark hold linstor-common linstor-satellite linstor-controller
systemctl is-active linstor-satellite
systemctl is-enabled linstor-controller
```][Die Version 1.35.3 kommt aus dem PPA. Die Paketinstallation startet den Satellite von selbst neu.]

#pruefe[
```
Setting up linstor-satellite (1.35.3-1ppa1~noble1) ...
Setting up linstor-controller (1.35.3-1ppa1~noble1) ...
active
disabled
```
`linstor-controller` bleibt `disabled`. Das Paket respektiert das, drbd-reactor behält die Kontrolle. In `linstor node list` steht `k0s-w1` jetzt auf `OFFLINE`, Satellite 1.35 gegen Controller 1.33.
]

Dasselbe auf `k0s-w3`, auf der Witness `k0s-ctrl` ohne das Paket `linstor-controller`.

Jetzt der Node mit dem aktiven Controller, `k0s-w2`. Im Lab wurde das Paket dort direkt installiert, und das Journal zeigt, was dann geschah:

#pruefe[
```
drbd-reactor: INFO  systemd_start: systemctl start drbd-services@linstor_db.target
drbd-linstor_db: linstor_db: State change failed: (-1) Multiple primaries not allowed by config
drbd-reactor: WARN  Starting 'linstor_db' failed: Return code not status success
systemd: Dependency failed for linstor-controller.service - drbd-reactor controlled linstor-controller.
```
Das Paket hat den laufenden Controller gestoppt. drbd-reactor hat die ganze Kette heruntergefahren, und `k0s-w3`, bereits auf 1.35, hat übernommen. Ein Versuch, auf `k0s-w2` neu zu starten, scheitert richtigerweise, weil `k0s-w3` jetzt Primary ist.
]

Am Ende lief alles, aber über einen ungeplanten Failover. Sauber ist es, den Controller vorher abzugeben:

#cmd("k0s-w2")[```bash
sudo drbd-reactorctl evict linstor_db
V=1.35.3-1ppa1~noble1
sudo apt-mark unhold linstor-common linstor-satellite linstor-controller
sudo apt-get install -y linstor-common=$V linstor-satellite=$V linstor-controller=$V
sudo apt-mark hold linstor-common linstor-satellite linstor-controller
```][Der Controller startet auf einem Node, der schon 1.35 hat, und erst dann wird das Paket auf `k0s-w2` getauscht.]

#cmd("k0s-w3")[```bash
linstor controller version
linstor node list
linstor resource list --faulty
```][Prüft das Ergebnis.]

#pruefe[
```
linstor controller 1.35.3; GIT-hash: 75d5fa72d504ccfe55c421ccccda9505af8371f8
│ Node     │ Platform │ NodeType  │ Addresses                 │ State  │
│ k0s-ctrl │ LINUX    │ SATELLITE │ 172.16.0.176:3366 (PLAIN) │ Online │
│ k0s-w1   │ LINUX    │ SATELLITE │ 10.10.0.11:3366 (PLAIN)   │ Online │
│ k0s-w2   │ LINUX    │ SATELLITE │ 10.10.0.12:3366 (PLAIN)   │ Online │
│ k0s-w3   │ LINUX    │ SATELLITE │ 10.10.0.13:3366 (PLAIN)   │ Online │
```
`--faulty` ist leer. Neu ist die Spalte `Platform`.
]

== Was mit der Controller-Datenbank passiert

Beim ersten Start von 1.35 migriert der Controller seine Datenbank auf ein neues H2-Format. Das steht in der Unit-Datei:

#cmd("k0s-w1")[```bash
systemctl cat linstor-controller | grep ExecStartPre
sudo ls -la /var/lib/linstor/
```][Die Startschritte und der Inhalt der Datenbank-Ressource, auf dem Node mit dem aktiven Controller.]

#pruefe[
```
ExecStartPre=/usr/share/linstor-server/bin/linstor-database migrate-h2 --yes ...
-rw-r--r-- 1 linstor-controller root   6442 Nov 12 20:16 auto_db_export_2026-11-12_20-16-01.json.gz
-rw-r--r-- 1 linstor-controller root 135168 Nov 12 20:19 linstordb.mv.db
-rw-r--r-- 1 linstor-controller root 839680 Nov 12 20:15 linstordb.mv.db.h2v1.bak
```
]

Der Controller hat vor der Migration selbst zwei Sicherungen angelegt: die alte Datei als `.h2v1.bak` und einen JSON-Export. Beide liegen auf `linstor_db` und sind damit auf drei Nodes repliziert. Ab jetzt läuft der Controller als eigener Benutzer `linstor-controller`.

#warum[
  Die Migration ist eine Einbahnstraße: Ein Controller 1.33 kann die neue Datei nicht mehr lesen. Ein Rückweg auf 1.33 ginge nur über die Sicherung, die vor der Migration entstanden ist. Kopiere `auto_db_export_*.json.gz` deshalb nach dem Update zusätzlich an einen anderen Ort.
]

#hinweis("Datenbank-Export von Hand: nicht erfolgreich getestet", warn, warn-hell)[
  LINSTOR hat ein Werkzeug `linstor-database export-db`. Laut Handbuch muss dafür der Controller gestoppt sein. Mit drbd-reactor reicht ein `systemctl stop linstor-controller` nicht: drbd-reactor fährt dann die Kette herunter, und ein anderer Node übernimmt. Im Lab funktionierte der Stopp so: `drbd-reactorctl disable linstor_db` auf den Standby-Nodes, dann `drbd-reactorctl disable --now linstor_db` auf dem aktiven Node, danach `linstor_db` von Hand zum Primary machen und mounten. Der Export scheiterte dann aber mit `Schema "LINSTOR" not found ... The database has pending migrations`. Die Ursache wurde nicht geklärt. Verlass dich für einen Rückweg auf die automatische Sicherung oben und auf `drbd-reactorctl enable linstor_db` auf allen Kandidaten, um den Wartungsmodus zu beenden.
]

== CSI aktualisieren

Jetzt darf der Pin fallen:

#datei("lab/piraeus/linstor-cluster-values.yaml (Ausschnitt)", ```yaml
          - name: linstor-csi
            image: quay.io/piraeusdatastore/piraeus-csi:v1.13.1
```)

#cmd("Mac")[```bash
helm upgrade linstor-cluster piraeus-charts/linstor-cluster --version 1.2.0 \
  -n piraeus-datastore -f lab/piraeus/linstor-cluster-values.yaml
kubectl -n piraeus-datastore rollout status ds/linstor-csi-node
kubectl get linstorcluster -o \
  jsonpath='{range .items[].status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```][Rollt CSI 1.13.1 aus.]

#pruefe[
```
Applied=True Resources applied
Available=True Controller 1.35.3 (API: 1.29.1, Git: 75d5fa72...) reachable at 'http://10.10.0.100:3370'
Configured=True Properties applied
```
Der Client aus Kapitel 10 meldete während des gesamten LINSTOR- und CSI-Updates keinen Fehler.
]

== Was 1.35 ändert und was nicht

#tabelle(
  (auto, auto, auto),
  ([Thema], [1.33.3], [1.35.3]),
  [Snapshots mit klassischem LVM], [nicht möglich], [*möglich*],
  [Vergrößern mit Writecache], [Writecache-Gerät wächst nicht mit], [*unverändert fehlerhaft*],
)

#cmd("k0s-w2")[```bash
linstor storage-pool list -s pool_data
```][`CanSnapshots` ist jetzt `True`.]

Der Snapshot-Versuch aus Kapitel 13 gelingt jetzt:

#pruefe[
```
pg-vor-update   true   data-pg-0   2Gi   linstor-snapshots   snapcontent-10131a8f-...
│ pvc-55d1f760-... │ snapshot-10131a8f-... │ k0s-w2, k0s-w3 │ 0: 2 GiB │ ... │ Successful │
  pvc-55d1f760-..._00000                       data owi-aos---   2.00g
  pvc-55d1f760-..._00000_snapshot-10131a8f-... data sri-a-s--k   2.00g   pvc-55d1f760-..._00000
```
Ein PVC aus diesem Snapshot (`lab/k8s/aus-snapshot.yaml`) enthielt den vollständigen Datenbestand.
]

#falle[
  Ein Snapshot mit klassischem LVM reserviert sofort *die volle Größe* des Volumes, hier 2 GiB pro Node. Zehn Snapshots einer 100-GB-Datenbank brauchen 1 TB. Und laut Changelog lassen sich Volumes mit solchen Snapshots nicht vergrößern. Snapshots sind hier ein Werkzeug für kurze Zeit, etwa vor einem riskanten Update, kein Backup-Ersatz.
]

Das Vergrößern eines Writecache-Volumes von 1 GiB auf 1500 MiB unter 1.35.3 ergab dasselbe Bild wie in Kapitel 12: Kubernetes meldet `1500Mi`, das Daten-LV hat 3080192 Sektoren, das Writecache-Gerät weiter 2105344, das Dateisystem 977 MB. Zusätzlich wird das Vergrößern verweigert, solange ein Volume noch synchronisiert (`Cannot resize volume, because we have a non-UpToDate DRBD device`). Der Resizer versucht es später von selbst noch einmal.

== k0s aktualisieren

k0s ist der einfachste Teil. Die neue Version kommt in `lab/k0sctl.yaml`:

#datei("lab/k0sctl.yaml (Ausschnitt)", ```yaml
  k0s:
    version: v1.37.2+k0s.1
```)

#cmd("Mac")[```bash
k0sctl apply --config lab/k0sctl.yaml --concurrency 1
```][k0sctl aktualisiert erst den Controller, dann die Worker nacheinander. Jeden Worker leert es vorher (`drain`) und gibt ihn danach wieder frei.]

#pruefe[
```
level=info msg="==> Running phase: Upgrade controllers"
level=info msg="172.16.0.176:22: starting upgrade"
level=info msg="==> Running phase: Upgrade workers"
level=info msg="172.16.0.186:22: starting upgrade"
level=info msg="172.16.0.186:22: upgrade finished"
...
level=info msg="==> Finished in 5m14s"
```
]

#cmd("Mac")[```bash
kubectl get nodes
```][Eine Minute später.]

#pruefe[
```
NAME     STATUS   ROLES    AGE    VERSION
k0s-w1   Ready    <none>   ...    v1.37.2+k0s
k0s-w2   Ready    <none>   ...    v1.37.2+k0s
k0s-w3   Ready    <none>   ...    v1.37.2+k0s
```
Direkt nach dem Ende von k0sctl zeigte `k0s-w3` noch die alte Version, weil der kubelet sich gerade neu meldete.
]

Zwei Beobachtungen aus dem Lab:

- Der Drain von `k0s-w3` hat `pg-0` verschoben. Bis das Volume auf `k0s-w3` gelöst war, wartete der Pod etwa 30 Sekunden (`Volume is already exclusively attached to one node, waiting on detach`). Eine Datenbank mit einer einzigen Instanz hat bei jedem Drain ihres Nodes eine kurze Pause.
- Der Client aus Kapitel 10 lief zu diesem Zeitpunkt als einzelner Pod ohne Deployment. Der Drain hat ihn gelöscht, und niemand hat ihn neu gestartet. Alles, was einen Drain überleben soll, braucht einen Controller wie ein Deployment. `lab/k8s/pg-client.yaml` ist deshalb inzwischen ein Deployment.

#gelernt(
  [Erst LINSTOR, dann CSI. CSI 1.13 braucht LINSTOR 1.35.],
  [Satellites mit anderer Version als der Controller sind `OFFLINE`. DRBD läuft weiter.],
  [Den Node mit dem aktiven Controller zuletzt aktualisieren und vorher mit `evict` abgeben.],
  [LINSTOR 1.35 migriert seine Datenbank beim ersten Start und legt vorher Sicherungen auf `linstor_db` an.],
  [1.35 bringt Snapshots für klassisches LVM, die je die volle Volume-Größe belegen.],
  [Der Writecache-Fehler beim Vergrößern besteht in 1.35.3 weiter.],
  [`k0sctl apply --concurrency 1` aktualisiert k0s Node für Node mit Drain.],
)
