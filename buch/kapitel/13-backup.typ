#import "../lib.typ": *

#kapitel(
  [Betrieb: Snapshots und Backup],
  ziel: [Du weißt, warum es mit klassischem LVM keine Snapshots gibt, und sicherst Volumes stattdessen mit Velero auf Dateiebene in einen S3-Speicher an einem anderen Ort. Eine gelöschte Datenbank stellst du vollständig wieder her.],
  zeit: [60 Minuten],
  braucht: [Den Cluster aus Kapitel 8, Platz auf `k0s-ctrl` für den S3-Speicher, `velero` und `aws` auf dem Mac],
)

#warum[
  DRBD ist kein Backup. Es repliziert jeden Schreibvorgang sofort, auch ein versehentliches `DROP TABLE` oder ein `rm -rf`. Gegen Bedienfehler, Ransomware und gelöschte Namespaces hilft nur eine Kopie, die an einem anderen Ort liegt und älter ist als der Fehler.
]

== Snapshots: nicht mit klassischem LVM

Kubernetes kennt Volume-Snapshots über CSI. Dafür braucht es einen Snapshot-Controller und seine CRDs. k0s bringt beides nicht mit:

#cmd("Mac")[```bash
helm install snapshot-controller piraeus-charts/snapshot-controller --version 5.4.0 -n kube-system
kubectl get crd | grep snapshot.storage
```][Installiert Controller und CRDs.]

#datei("lab/k8s/snapshot.yaml", raw(read("../../lab/k8s/snapshot.yaml"), lang: "yaml", block: true))

#cmd("Mac")[```bash
kubectl apply -f lab/k8s/snapshot.yaml
kubectl get volumesnapshotcontent -o jsonpath='{range .items[*]}{.status.error.message}{"\n"}{end}'
```][Versucht einen Snapshot des PostgreSQL-Volumes.]

#pruefe[
```
failed to take snapshot of the volume pvc-0d903f58-...: "rpc error: code = Internal
desc = failed to create snapshot: failed to create snapshots: Message: 'Storage driver
'LVM' does not support snapshots.'; Details: 'Used for storage pool 'pool_data' on 'k0s-w1'.
```
]

Das stand schon in `linstor storage-pool list` in der Spalte `CanSnapshots: False`. Klassisches LVM kann in LINSTOR 1.33 keine Snapshots. Das hat Folgen:

- Kein schneller Rückweg vor einem riskanten Update der Anwendung.
- Keine Backups über LINSTOR selbst. LINSTOR kann Snapshots nach S3 versenden, aber eben nur Snapshots.
- Velero kann keine CSI-Snapshots nutzen.

#cmd("Mac")[```bash
kubectl -n demo delete volumesnapshot pg-vor-update
```][Räumt den gescheiterten Versuch ab.]

#hinweis("Ausblick", akzent, akzent-hell)[
  Mit LINSTOR 1.35 gehen Snapshots auch mit klassischem LVM. Kapitel 15 zeigt das nach dem Update, samt dem Haken: Jeder Snapshot belegt sofort die volle Größe des Volumes.
]

== Backup auf Dateiebene

Velero sichert Kubernetes-Objekte und, mit seinem Node-Agent, den Inhalt von Volumes Datei für Datei. Dafür liest der Node-Agent die gemounteten Volumes direkt auf dem Node, verschlüsselt und dedupliziert sie mit Kopia und legt sie in S3 ab. Snapshots braucht er dafür nicht.

=== Ein S3-Speicher am dritten Standort

Ein Backup gehört an einen anderen Ort als die Daten. Im Lab ist das `k0s-ctrl`, die Witness am „dritten Standort“. Dort läuft SeaweedFS als einzelnes Programm, außerhalb von Kubernetes:

#datei("lab/backup/seaweedfs.service", raw(read("../../lab/backup/seaweedfs.service"), lang: "ini", block: true), erklaerung: [`weed server` startet Master, Volume-Server und Filer in einem Prozess, `-s3` dazu die S3-Schnittstelle auf Port 8333. Die Zugangsdaten stehen in `/etc/seaweedfs/s3.json`.])

#datei("/etc/seaweedfs/s3.json", ```json
{"identities":[{"name":"velero",
  "credentials":[{"accessKey":"velero","secretKey":"<40 Zeichen Zufall>"}],
  "actions":["Admin","Read","Write","List","Tagging"]}]}
```, erklaerung: [Den Schlüssel erzeugst du mit `openssl rand -hex 20`. Dieselben Werte landen in `lab/backup/velero-credentials` im Format einer AWS-Credentials-Datei. Beide Dateien stehen in `.gitignore`.])

#cmd("k0s-ctrl")[```bash
cd /tmp
curl -sSfL -o weed.tgz https://github.com/seaweedfs/seaweedfs/releases/download/4.53/linux_amd64.tar.gz
tar xzf weed.tgz weed
sudo install -m 755 weed /usr/local/bin/weed
sudo install -d -m 700 /etc/seaweedfs /var/lib/seaweedfs
sudo install -m 600 /tmp/s3.json /etc/seaweedfs/s3.json
sudo install -m 644 /tmp/seaweedfs.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now seaweedfs
```][`s3.json` und die Unit-Datei hast du vorher mit `scp` nach `/tmp` kopiert.]

#cmd("Mac")[```bash
export AWS_ACCESS_KEY_ID=velero AWS_SECRET_ACCESS_KEY=<Schlüssel>
aws --endpoint-url http://172.16.0.176:8333 s3 mb s3://velero
aws --endpoint-url http://172.16.0.176:8333 s3 ls
```][Legt den Bucket an.]

#pruefe[
```
make_bucket: velero
2026-11-12 21:06:33 velero
```
]

=== Velero installieren

#datei("lab/backup/velero-values.yaml", raw(read("../../lab/backup/velero-values.yaml"), lang: "yaml", block: true), erklaerung: [
  `defaultVolumesToFsBackup: true` sichert jedes Volume per Kopia, ohne dass du Pods einzeln markieren musst.
  `snapshotsEnabled: false`, weil es keine Snapshots gibt.
])

#falle[
  Der kubelet-Pfad schlägt wieder zu. Der Node-Agent sucht die Volumes der Pods unter `/var/lib/kubelet/pods`. Auf k0s liegen sie unter `/var/lib/k0s/kubelet/pods`. Ohne `nodeAgent.podVolumePath` findet der Node-Agent die Volumes nicht. Im Lab wurde gleich mit dem richtigen Pfad installiert, die Fehlermeldung ohne ihn ist hier also nicht gezeigt.
]

#cmd("Mac")[```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
kubectl create namespace velero
kubectl -n velero create secret generic velero-s3 --from-file=cloud=lab/backup/velero-credentials
helm install velero vmware-tanzu/velero --version 12.2.4 -n velero -f lab/backup/velero-values.yaml
velero -n velero backup-location get
```][Installiert Velero 1.18 mit dem AWS-Plugin für S3.]

#pruefe[
```
NAME      PROVIDER   BUCKET/PREFIX   PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        velero          Available   2026-11-12 21:07:23 +0100 CET   ReadWrite     true
```
]

== Sichern

#cmd("Mac")[```bash
velero -n velero backup create demo-1 --include-namespaces demo --wait
velero -n velero backup describe demo-1 --details
```][Sichert den Namespace `demo` mit der Datenbank.]

#pruefe[
```
Backup completed with status: Completed.
...
  Pod Volume Backups - kopia:
    Completed:
      demo/pg-0: data (size: 40459477, incremental size: 40459477)
```
Die erste Sicherung überträgt alles, 40 MB. Weitere Sicherungen übertragen nur die Änderungen.
]

#hinweis("Konsistenz", warn, warn-hell)[
  Velero kopiert die Dateien einer laufenden Datenbank. PostgreSQL verkraftet das wie einen Stromausfall: Beim Start spielt es sein Write-Ahead-Log nach. Für eine wirklich konsistente Sicherung gehört ein Pre-Hook dazu, der vor dem Kopieren einen `CHECKPOINT` auslöst oder die Datenbank per `pg_dump` sichert. Velero unterstützt das über Annotationen am Pod.
]

== Wiederherstellen

Jetzt der Ernstfall: Jemand löscht den Namespace.

#cmd("Mac")[```bash
kubectl delete namespace demo
```][Mit dem Namespace verschwinden PVC, PV und das LINSTOR-Volume.]

#cmd("k0s-w2")[```bash
linstor resource-definition list
```][Das Volume der Datenbank ist weg, nur `linstor_db` steht noch da.]

#cmd("Mac")[```bash
velero -n velero restore create demo-1-restore --from-backup demo-1 --wait
kubectl -n demo rollout status sts/pg
kubectl -n demo exec pg-0 -- psql -U postgres -c "select text from notizen;" -c "select count(*) from puls;"
```][Stellt alle Objekte wieder her. Für das PVC legt LINSTOR ein neues Volume an, der Node-Agent kopiert die Dateien hinein, bevor PostgreSQL startet.]

#pruefe[
```
Restore completed with status: Completed.
          text
------------------------
 geschrieben auf k0s-w2
 count
-------
  2027
```
Die erste Zeile aus Kapitel 8 und alle Einträge des Pulsmessers bis zum Zeitpunkt der Sicherung.
]

#cmd("k0s-w2")[```bash
linstor resource list -r pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250
```][Das neue Volume.]

#pruefe[
```
│ k0s-ctrl │ DRBD,STORAGE            │ Unused │ Ok    │           Diskless │ Yes  │
│ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ SyncTarget(36.36%) │ Yes  │
│ k0s-w3   │ DRBD,WRITECACHE,STORAGE │ InUse  │ Ok    │           UpToDate │ Yes  │
```
Ein neues Volume mit neuem Namen, wieder in zwei Zonen und mit Writecache. Die Zuordnung zu Nodes ist eine andere als vorher, das ist normal.
]

Zeitbedarf im Lab: Sicherung 15 Sekunden, Wiederherstellung 21 Sekunden, bei 40 MB Daten. Bei einer echten Datenbank mit vielen Gigabyte bestimmt der Durchsatz zwischen Cluster und S3 die Zeit. Miss das in deiner Umgebung einmal, bevor du es im Ernstfall brauchst.

#falle[
  Ein Backup, das nie wiederhergestellt wurde, ist eine Hoffnung. Plane die Wiederherstellung in einen eigenen Namespace als regelmäßige Übung ein: `velero restore create --namespace-mappings demo:demo-test`.
]

#gelernt(
  [DRBD ist kein Backup. Es repliziert auch Fehler.],
  [Mit klassischem LVM gibt es in LINSTOR 1.33 keine Snapshots.],
  [Velero mit Node-Agent sichert Volumes Datei für Datei mit Kopia in S3.],
  [Auf k0s braucht der Node-Agent den Pfad `/var/lib/k0s/kubelet/pods`.],
  [Das Backup-Ziel liegt außerhalb des Clusters und an einem anderen Ort.],
  [Ein Restore legt neue LINSTOR-Volumes an und füllt sie vor dem Start der Anwendung.],
)
