#import "../lib.typ": *

#kapitel(
  [Betrieb: Wenn der Platz ausgeht],
  ziel: [Du erkennst ein volles Volume und einen vollen Pool, vergrößerst Volumes im laufenden Betrieb und kennst die Falle, in die Writecache-Volumes dabei laufen.],
  zeit: [40 Minuten],
  braucht: [Den Cluster mit StorageClass aus Kapitel 8],
)

Alle Versuche in diesem Kapitel laufen in einem eigenen Namespace mit einem kleinen Test-Volume:

#datei("lab/k8s/fueller.yaml (Ausschnitt)", ```yaml
kind: PersistentVolumeClaim
metadata: {name: klein, namespace: kapazitaet}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
kind: Pod
metadata: {name: fueller, namespace: kapazitaet}
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: [sleep, "86400"]
      volumeMounts: [{name: daten, mountPath: /daten}]
```)

#cmd("Mac")[```bash
kubectl apply -f lab/k8s/fueller.yaml
kubectl -n kapazitaet wait --for=condition=Ready pod/fueller
```][Legt Namespace, PVC und einen Pod mit einer Shell an.]

== Ein volles Volume

#cmd("Mac")[```bash
kubectl -n kapazitaet exec fueller -- dd if=/dev/zero of=/daten/gross bs=1M count=2000
kubectl -n kapazitaet exec fueller -- df -h /daten
kubectl -n kapazitaet exec fueller -- sh -c 'echo test > /daten/neu'
```][Schreibt 2 GB in ein 1-GB-Volume.]

#pruefe[
```
1007722496 bytes (961.0MB) copied, 3.630850 seconds, 264.7MB/s
command terminated with exit code 1
Filesystem                Size      Used Available Use% Mounted on
/dev/drbd1002           977.1M    961.1M         0 100% /daten
sh: write error: No space left on device
```
]

Für DRBD und LINSTOR ist das kein Fehler. Das Dateisystem ist voll, das Gerät darunter ist gesund. `drbdadm status` zeigt weiter `UpToDate`. Die Anwendung sieht `No space left on device` (ENOSPC). Eine Datenbank stoppt dann in der Regel oder geht in einen Nur-Lese-Modus.

#warum[
  Im Betrieb heißt das: Ein voller PVC ist ein Fall für die Anwendung und das Monitoring, nicht für den Storage. Die Lösung ist Vergrößern. Wie gut das klappt, hängt allerdings vom Storage ab, wie der nächste Abschnitt zeigt.
]

== Vergrößern im laufenden Betrieb

Die StorageClass erlaubt das Vergrößern (`allowVolumeExpansion: true`). Du änderst nur die Größe im PVC:

#cmd("Mac")[```bash
kubectl -n kapazitaet patch pvc klein -p '{"spec":{"resources":{"requests":{"storage":"3Gi"}}}}'
kubectl -n kapazitaet describe pvc klein | tail -3
```][Fordert 3 GiB statt 1 GiB an.]

#pruefe[
```
Warning  VolumeResizeFailed  external-resizer linstor.csi.linbit.com  resize volume
  "pvc-370b3c44-..." failed: ... Cannot grow the volume definition by 2097152KiB,
  as the following storage pool do not have enough free space:
Node: k0s-w1, StorPool: pool_nvme
Node: k0s-w2, StorPool: pool_nvme
```
]

#falle[
  *LINSTOR prüft beim Vergrößern den vollen Zuwachs gegen jeden Pool des Volumes*, auch gegen den Cache-Pool. Der Writecache braucht nur 5 % des Zuwachses, also gut 100 MB. LINSTOR verlangt aber 2 GiB freien Platz in `pool_nvme`, und dort sind nur 1,84 GiB frei. Mit einer Cache-VG von etwa 5 % der Datenplatte heißt das: *Jede Vergrößerung, die größer ist als der freie Platz auf der NVMe, scheitert*, auch wenn auf der HDD Terabytes frei sind.
]

Kubernetes erlaubt seit Version 1.34, eine gescheiterte Vergrößerung auf einen kleineren Wert zurückzunehmen, solange er größer ist als die aktuelle Größe:

#cmd("Mac")[```bash
kubectl -n kapazitaet patch pvc klein -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl -n kapazitaet get pvc klein
```][1 GiB Zuwachs passt in den Cache-Pool.]

#pruefe[
```
NAME    STATUS   VOLUME             CAPACITY   ACCESS MODES   STORAGECLASS
klein   Bound    pvc-370b3c44-...   2Gi        RWO            linstor-replicated
```
Kubernetes meldet 2 GiB, und die Ereignisse zeigen `FileSystemResizeSuccessful`.
]

Jetzt die Probe im Pod:

#cmd("Mac")[```bash
kubectl -n kapazitaet exec fueller -- df -h /daten
```][Wie groß ist das Dateisystem wirklich?]

#pruefe[
```
Filesystem                Size      Used Available Use% Mounted on
/dev/drbd1002           977.1M    961.1M         0 100% /daten
```
Immer noch 977 MB.
]

== Schicht für Schicht suchen

Kubernetes sagt 2 GiB, das Dateisystem 1 GiB. Irgendwo dazwischen hängt die Größe. Du gehst den Gerätestapel von unten nach oben durch, auf dem Node, auf dem der Pod läuft:

#cmd("k0s-w1")[```bash
sudo lvs -o lv_name,lv_size data cache | grep pvc-370b
sudo dmsetup table | grep pvc-370b
sudo blockdev --getsize64 /dev/drbd1002
```][LVs, Writecache-Gerät und DRBD-Gerät.]

#pruefe[
```
  pvc-370b3c44-....cache_00000 104.00m
  pvc-370b3c44-..._00000         2.00g
linstor_writecache_pvc-370b3c44-..._00000: 0 2105344 writecache s 252:4 252:5 4096 0
1077665792
```
]

#tabelle(
  (auto, auto, auto),
  ([Schicht], [Größe], [Gewachsen?]),
  [Daten-LV], [2,00 GiB], [ja],
  [Cache-LV], [104 MB (5 %)], [ja],
  [dm-writecache], [2105344 Sektoren = 1 GiB], [*nein*],
  [DRBD], [1 GiB], [nein, weil die Schicht darunter nicht gewachsen ist],
  [Dateisystem], [977 MB], [nein],
)

Das Satellite-Journal bestätigt es:

#cmd("k0s-w1")[```bash
sudo journalctl -u linstor-satellite --since "-10min" | grep resized
```][Was LINSTOR beim Vergrößern getan hat.]

#pruefe[
```
... Volume number 0 of resource 'pvc-370b3c44-...' [LVM] resized
... Volume number 0 of resource 'pvc-370b3c44-....cache' [LVM] resized
... DRBD resized pvc-370b3c44-.../0
```
Beide LVs vergrößert, DRBD „vergrößert“. Für die Writecache-Schicht steht nichts da, und es gibt keinen Fehlerbericht.
]

#hinweis("Ein stiller Fehler in LINSTOR 1.33.3", warn, warn-hell)[
  Mit der Schicht WRITECACHE wird das Device-Mapper-Gerät beim Vergrößern nicht neu geladen. LINSTOR, CSI und Kubernetes melden Erfolg, die Anwendung bekommt keinen zusätzlichen Platz. Im Changelog von LINSTOR bis 1.35.3 ist dazu kein Fix vermerkt, und ein Test nach dem Update auf 1.35.3 in Kapitel 15 zeigt dasselbe Verhalten. Prüfe nach jeder Vergrößerung eines Writecache-Volumes mit `df` im Pod, ob sie wirklich angekommen ist.
]

== Der Ausweg von Hand

Das Writecache-Gerät lässt sich im laufenden Betrieb mit der neuen Länge neu laden. Das machst du auf *jedem* Node mit einer Datenkopie, hier `k0s-w1` und `k0s-w2`:

#cmd("k0s-w1")[```bash
R=pvc-370b3c44-87e5-478e-a380-adb44aa460e9
D=linstor_writecache_${R}_00000
sudo dmsetup table $D
sudo blockdev --getsz /dev/data/${R}_00000
```][Die alte Tabelle und die neue Länge des Daten-LVs in Sektoren.]

#pruefe[
```
0 2105344 writecache s 252:4 252:5 4096 0
4202496
```
]

#cmd("k0s-w1")[```bash
sudo dmsetup suspend $D
echo "0 4202496 writecache s 252:4 252:5 4096 0" | sudo dmsetup reload $D
sudo dmsetup resume $D
sudo dmsetup table $D
```][Die Tabelle bleibt gleich bis auf die zweite Zahl, die Länge. `suspend` hält kurz alle Zugriffe an, `reload` lädt die neue Tabelle, `resume` gibt das Gerät wieder frei.]

#falle[
  Übernimm die Gerätenummern (`252:4 252:5`) aus deiner eigenen Ausgabe von `dmsetup table`, nicht aus dem Buch. Sie sind auf jedem Node anders. Eine falsche Nummer verbindet das Writecache-Gerät mit einem fremden LV.
]

Danach, nur auf dem Primary:

#cmd("k0s-w1")[```bash
sudo drbdadm resize $R
sudo drbdadm status $R
sudo resize2fs /dev/drbd1002
```][`drbdadm resize` lässt DRBD die neue Größe der Geräte darunter übernehmen. Den neuen Bereich synchronisiert DRBD zur Gegenseite. `resize2fs` vergrößert das gemountete ext4 online.]

#pruefe[
```
  k0s-w2 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:19.73
The filesystem on /dev/drbd1002 is now 525190 (4k) blocks long.
```
Die Gegenseite gleicht den neuen Bereich ab. Im Pod:
```
Filesystem                Size      Used Available Use% Mounted on
/dev/drbd1002             1.9G    961.1M    921.6M  51% /daten
```
]

#warum[
  Diesen Weg gehst du in Produktion nur, wenn eine Vergrößerung wirklich gebraucht wird. Die Alternative ohne Handarbeit: ein neues, größeres PVC anlegen und die Daten auf Anwendungsebene umziehen, etwa mit `pg_dump`. Melde den Fehler außerdem an LINBIT. Ein Volume, das laut allen Werkzeugen größer ist, als es ist, gehört behoben und nicht dauerhaft umgangen.
]

== Ein voller Pool

#cmd("Mac")[```bash
kubectl apply -f lab/k8s/zu-gross.yaml
kubectl -n kapazitaet get pvc zu-gross
kubectl -n kapazitaet get events --field-selector involvedObject.name=zu-gross,reason=ProvisioningFailed
```][Ein PVC mit 40 GiB, die Pools haben je 30 GiB.]

#pruefe[
```
NAME       STATUS    VOLUME   CAPACITY   ...
zu-gross   Pending                       ...
... ResourceExhausted desc = failed to enough replicas on requisite nodes:
  Message: 'Not enough available nodes'; Details: 'Not enough nodes fulfilling
  the following auto-place criteria:
 * has a deployed storage pool named [pool_data]
 * the storage pools have to have at least '41943040' free space
 ...
   Replica count: 2
   Replicas on nodes with different property:
      Aux/zone
```
]

Die Meldung ist ausführlich und ehrlich: kein Node mit 40 GiB frei. Der Pod bleibt `Pending`, nichts ist halb angelegt. Bei knappem Platz scheitert die Platzierung allerdings oft schon früher, als die freien Gigabytes vermuten lassen:

- Wegen `--replicas-on-different zone` braucht es *in jeder Zone* einen Node mit genug Platz. Zone b hat im Lab nur `k0s-w2`.
- Auch `pool_nvme` muss die 5 % für den Cache haben.

#cmd("k0s-w1")[```bash
linstor storage-pool list -s pool_data pool_nvme
```][Der freie Platz pro Node und Pool. Das ist die Zahl, die das Monitoring im Blick haben muss.]

#cmd("Mac")[```bash
kubectl delete namespace kapazitaet
```][Räumt die Tests ab. LINSTOR löscht die Volumes mit.]

#gelernt(
  [Ein volles Dateisystem ist kein Storage-Fehler. Die Anwendung sieht ENOSPC, DRBD bleibt gesund.],
  [LINSTOR verlangt den vollen Zuwachs auch im Writecache-Pool.],
  [Mit Writecache wächst das Volume in LINSTOR 1.33.3 nicht wirklich mit. Kontrolle mit `df` im Pod ist Pflicht.],
  [Den Gerätestapel prüfst du von unten nach oben: `lvs`, `dmsetup table`, `blockdev`, `df`.],
  [Ein voller Pool lässt das PVC `Pending`. Die Meldung nennt die Platzierungskriterien.],
  [Platz muss pro Zone und auch im Cache-Pool reichen.],
)
