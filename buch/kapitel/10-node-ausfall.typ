#import "../lib.typ": *

#kapitel(
  [Betrieb: Wenn ein Node ausfällt],
  ziel: [Du wartest einen Node geplant ohne Ausfall, weißt, was bei einem Absturz passiert, und holst eine Datenbank zurück, deren Node nicht wiederkommt.],
  zeit: [60 Minuten],
  braucht: [Den Cluster aus Kapitel 8 mit der PostgreSQL-Datenbank],
)

== Den Ausfall messbar machen

Ein Client fügt jede Sekunde eine Zeile in die Datenbank ein und protokolliert Erfolg oder Fehler. So siehst du später auf die Sekunde, wie lange die Datenbank weg war.

#datei("lab/k8s/pg-client.yaml (Ausschnitt)", ```yaml
          while true; do
            if timeout 3 psql -h pg -U postgres -qc "insert into puls default values" 2>/dev/null; then
              echo "$(date +%T) ok"
            else
              echo "$(date +%T) FEHLER"
            fi
            sleep 1
          done
```, erklaerung: [Dazu gehört ein Service `pg`, damit der Client die Datenbank unabhängig vom Node findet. Der Client ist ein Deployment, damit er einen Drain übersteht (Kapitel 15). Bei den Messungen in diesem Kapitel lief er als einzelner Pod auf `k0s-w3`.])

#cmd("Mac")[```bash
kubectl apply -f lab/k8s/pg-client.yaml
kubectl -n demo logs deploy/pg-client --tail=3
```][Startet den Client.]

== Geplante Wartung

Ein Node soll neu starten, etwa für ein Kernel-Update. Im Lab trifft es `k0s-w3`, auf dem gerade der LINSTOR-Controller läuft.

#cmd("Mac")[```bash
kubectl drain k0s-w3 --ignore-daemonsets --delete-emptydir-data
```][Verschiebt alle Pods außer den DaemonSets auf andere Nodes und sperrt den Node für neue Pods.]

#cmd("k0s-w3")[```bash
sudo drbd-reactorctl status linstor_db | head -2
sudo drbd-reactorctl evict linstor_db
```][Läuft der Controller hier, gibt der Node ihn geplant ab.]

#pruefe[
```
Node 'k0s-w1' took over
```
]

#falle[
  Direkt nach `evict` meldet `linstor` noch einige Sekunden `Connection refused` von der VIP. Der Controller startet auf dem neuen Node gerade, Java braucht dafür ein paar Sekunden. Warte, bis `linstor node list` antwortet, bevor du den Node neu startest.
]

#cmd("k0s-w3")[```bash
sudo systemctl reboot
```][Der eigentliche Neustart.]

Während `k0s-w3` weg ist, zeigt `drbdadm status linstor_db` auf den anderen Nodes `k0s-w3 connection:Connecting`. Nach etwa 30 Sekunden ist der Node zurück:

#cmd("k0s-w1")[```bash
linstor node list
linstor resource list --faulty
```][`--faulty` zeigt nur Ressourcen mit Problemen.]

#pruefe[
```
│ k0s-w3   │ SATELLITE │ 10.10.0.13:3366 (PLAIN)   │ OFFLINE │
│ linstor_db   │ k0s-w3 │ DRBD,STORAGE │       │       │ Unknown │ Yes  │
```
Ein paar Sekunden nach dem Neustart steht der Node noch auf `OFFLINE`, obwohl DRBD schon wieder verbunden ist. Der Controller verbindet sich in Intervallen neu. Kurz darauf:
```
│ k0s-w3   │ SATELLITE │ 10.10.0.13:3366 (PLAIN)   │ Online │
```
und `resource list --faulty` ist leer.
]

#cmd("Mac")[```bash
kubectl uncordon k0s-w3
```][Gibt den Node wieder frei.]

Drain, Abgabe des Controllers, Neustart, Resync und Freigabe dauerten im Lab zusammen etwa zwei Minuten. Die Datenbank war in dieser Zeit durchgehend erreichbar.

#warum[
  Die Reihenfolge ist wichtig: erst die Pods weg, dann der Controller, dann der Neustart. Würdest du einen Node mit aktivem Controller einfach neu starten, ginge der Controller trotzdem auf einen anderen Node über, aber ungeplant, mit einem Timeout statt in Sekunden.
]

== Ein Absturz

Jetzt der unschöne Fall: `k0s-w1` stürzt ab. Auf ihm laufen sowohl PostgreSQL als auch der LINSTOR-Controller. Ein Absturz lässt sich mit SysRq nachstellen. `b` startet den Kernel sofort neu, ohne Sync und ohne Herunterfahren, wie der Reset-Knopf.

#cmd("k0s-w1")[```bash
echo 1 | sudo tee /proc/sys/kernel/sysrq
echo b | sudo tee /proc/sysrq-trigger
```][Die SSH-Verbindung reißt sofort ab.]

#falle[
  SysRq ist ein Notfallwerkzeug. Führe diese Befehle nur im Lab aus und nur auf dem Node, den du meinst. Es gibt keine Rückfrage.
]

Was dann geschah, in Zahlen aus dem Lab:

#tabelle(
  (auto, 1fr),
  ([Zeitpunkt], [Ereignis]),
  [0 s], [Absturz von `k0s-w1`. Der Client meldet ab jetzt `FEHLER`.],
  [38 s], [LINSTOR-Controller auf `k0s-w2` gestartet und über die VIP erreichbar.],
  [ca. 30 s], [`k0s-w1` bootet wieder, DRBD verbindet sich und gleicht ab.],
  [bis 120 s], [`pg-0` bleibt auf `k0s-w1` und wartet. Fehler: `driver name linstor.csi.linbit.com not found in the list of registered CSI drivers`.],
  [ca. 122 s], [CSI-Node-Pod auf `k0s-w1` läuft, das Volume wird gemountet, PostgreSQL startet. Der Client meldet wieder `ok`.],
)

#cmd("Mac")[```bash
kubectl -n demo describe pod pg-0 | tail -8
```][Die Ereignisse am Pod nach dem Neustart des Nodes.]

#pruefe[
```
Warning  NodeNotReady   node-controller  Node is not ready
Warning  FailedMount    kubelet          MountVolume.MountDevice failed ... driver name
         linstor.csi.linbit.com not found in the list of registered CSI drivers
Normal   SandboxChanged kubelet          Pod sandbox changed, it will be killed and re-created.
Normal   Started        kubelet          spec.containers{postgres}: Container started
```
]

Zwei Minuten Ausfall, kein Datenverlust, keine Handarbeit. Kubernetes hat den Pod nicht verschoben, weil der Node schnell genug zurück war. Die meiste Zeit verging mit dem Warten auf den CSI-Treiber nach dem Neustart.

== Ein Node, der nicht zurückkommt

Der schwerste Fall: `k0s-w1` fällt aus und bleibt aus, etwa wegen eines defekten Netzteils. Im Lab schaltet SysRq `o` die VM sofort aus.

#cmd("k0s-w1")[```bash
sudo sysctl -w kernel.sysrq=1
sudo systemd-run --on-active=2 sh -c "echo o > /proc/sysrq-trigger"
```][Schaltet die VM in zwei Sekunden hart ab. Die Verzögerung sorgt dafür, dass die SSH-Sitzung den Befehl noch sauber übergibt. Wieder einschalten kannst du sie nur über Proxmox.]

#cmd("Mac")[```bash
kubectl get nodes
kubectl -n demo get pod -o wide
```][Nach einer Minute und nach sechs Minuten.]

#pruefe[
```
## nach 1 Minute
k0s-w1   NotReady   ...
pg-0        1/1   Running       ...   k0s-w1
## nach 6 Minuten
k0s-w1   NotReady   ...
pg-0        1/1   Terminating   ...   k0s-w1
```
Der Client meldet die ganze Zeit `FEHLER`.
]

Nach fünf Minuten markiert Kubernetes den Pod zum Löschen. Löschen kann ihn aber nur das kubelet auf `k0s-w1`, und das ist aus. Der Pod bleibt in `Terminating`, das StatefulSet startet keinen Ersatz. Eine zweite `pg-0` darf es nie geben. Kubernetes kann nicht unterscheiden, ob der Node tot ist oder nur nicht erreichbar und die alte Instanz noch schreibt.

#warum[
  Auf der Speicherseite ist alles bereit: `k0s-w2` hat eine aktuelle Kopie und mit der Witness die Mehrheit. Was fehlt, ist die Bestätigung, dass `k0s-w1` wirklich nicht mehr schreibt. Diese Bestätigung muss ein Mensch geben. Der Piraeus-HA-Controller könnte das automatisch tun. In diesem Buch ist er bewusst abgeschaltet, also braucht es jemanden, der den Knopf drückt.
]

Der Knopf ist das *Out-of-Service-Taint*. Du setzt es erst, wenn du sicher weißt, dass der Node aus ist, etwa weil du ihn in Proxmox ausgeschaltet siehst:

#cmd("Mac")[```bash
kubectl taint node k0s-w1 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
```][Kubernetes löscht daraufhin alle Pods des Nodes zwangsweise und gibt ihre Volumes frei.]

#pruefe[
```
pg-0   1/1   Running   0   11s   10.244.1.10   k0s-w3
Normal  Scheduled               Successfully assigned demo/pg-0 to k0s-w3
Normal  SuccessfulAttachVolume  AttachVolume.Attach succeeded for volume "pvc-0d903f58-..."
Normal  Started                 spec.containers{postgres}: Container started
```
30 Sekunden nach dem Taint lief die Datenbank wieder, mit allen Daten.
]

#falle[
  Setze das Taint *nie* auf einen Node, der vielleicht noch läuft. Lebt die alte Instanz noch und erreicht ihr Storage-Netz, schützt dich DRBD-Quorum vor doppeltem Schreiben, aber die Anwendung auf dem alten Node bekommt I/O-Fehler (Kapitel 11, Versuch D). Erst ausschalten, dann das Taint setzen.
]

Ein Blick auf LINSTOR zeigt eine Überraschung:

#cmd("k0s-w2")[```bash
linstor resource list -r pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Wo die Kopien jetzt liegen.]

#pruefe[
```
│ k0s-ctrl │ DRBD,STORAGE            │ Unused │ Connecting(k0s-w1) │ Diskless │ Yes  │
│ k0s-w1   │ DRBD,WRITECACHE,STORAGE │        │                    │  Unknown │ Yes  │
│ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Connecting(k0s-w1) │ UpToDate │ Yes  │
│ k0s-w3   │ DRBD,STORAGE            │ InUse  │ Connecting(k0s-w1) │ Diskless │ Yes  │
```
]

Der Scheduler hat `pg-0` nach `k0s-w3` gesetzt, wo keine Kopie liegt. LINSTOR hat dort automatisch einen disklosen Zugang angelegt. Die Datenbank liest und schreibt übers Netz auf `k0s-w2`. Das funktioniert, kostet aber Latenz. Und es gibt gerade nur *eine* aktuelle Kopie der Daten.

== Der Node kommt zurück

Nach der Reparatur startest du `k0s-w1` in Proxmox. Die Kopie auf `k0s-w1` ist veraltet. DRBD erkennt das und gleicht sie ab, ohne dass du etwas tun musst:

#cmd("k0s-w2")[```bash
sudo drbdadm status pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Eine Minute nach dem Start von `k0s-w1`.]

#pruefe[
```
pvc-0d903f58-... role:Secondary
  disk:UpToDate open:no
  k0s-ctrl role:Secondary
    peer-disk:Diskless peer-client:yes
  k0s-w1 role:Secondary
    peer-disk:UpToDate
  k0s-w3 role:Primary
    peer-disk:Diskless peer-client:yes
```
Der Resync war bereits durch, als SSH wieder ging. Er überträgt nur die Blöcke, die sich in der Zwischenzeit geändert haben.
]

Kubernetes meldet den Node als `Ready`, aber auf ihm läuft fast nichts:

#cmd("Mac")[```bash
kubectl get pods -n piraeus-datastore -o wide --field-selector spec.nodeName=k0s-w1
```][Welche Piraeus-Pods auf `k0s-w1` laufen.]

#pruefe[
```
No resources found in piraeus-datastore namespace.
```
]

#falle[
  Das Out-of-Service-Taint hat den Effekt `NoExecute` und verdrängt *alle* Pods ohne passende Toleranz, auch den CSI-Node-DaemonSet. Solange es gesetzt ist, kann auf dem Node kein LINSTOR-Volume gemountet werden. Nimm es herunter, sobald der Node repariert ist.
]

#cmd("Mac")[```bash
kubectl taint node k0s-w1 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
kubectl get csinode k0s-w1 -o jsonpath='{.spec.drivers[*].name}{"\n"}'
```][Das Minus am Ende entfernt das Taint. Danach registriert sich der CSI-Treiber wieder.]

#pruefe[
```
node/k0s-w1 untainted
linstor.csi.linbit.com
```
]

Bleibt die Datenbank auf `k0s-w3` ohne eigene Kopie. Das ist kein Fehler, aber jeder Lese- und Schreibzugriff geht übers Netz. Du holst sie zurück auf einen Node mit Daten:

#cmd("Mac")[```bash
kubectl cordon k0s-w3
kubectl -n demo delete pod pg-0
kubectl -n demo wait --for=condition=Ready pod/pg-0
kubectl uncordon k0s-w3
```][Mit `k0s-w3` gesperrt bleiben nur Nodes mit Kopie, und der Scheduler muss einen davon nehmen.]

#cmd("k0s-w2")[```bash
linstor resource list -r pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Der Zustand danach.]

#pruefe[
```
│ k0s-ctrl │ DRBD,STORAGE            │ Unused │ Ok    │ Diskless │ Yes  │
│ k0s-w1   │ DRBD,WRITECACHE,STORAGE │ InUse  │ Ok    │ UpToDate │ Yes  │
│ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
```
Den disklosen Zugang auf `k0s-w3` hat LINSTOR beim Aushängen selbst entfernt. Der Umzug kostete die Datenbank etwa 6 Sekunden.
]

#hinweis("Warum LINSTOR nicht von selbst neue Kopien anlegt", akzent, akzent-hell)[
  LINSTOR kennt eine automatische Evakuierung: Ist ein Node länger als `DrbdOptions/AutoEvictAfterTime` offline (Standard 60 Minuten), legt es seine Kopien auf anderen Nodes neu an. In diesem Cluster ist das abgeschaltet, und zwar vom Piraeus-Operator. Er setzt am Controller `DrbdOptions/AutoEvictAllowEviction=false` (Kapitel 8). Ein ausgefallener Node bleibt also ausgefallen, bis du ihn reparierst oder seine Kopien bewusst verschiebst (Kapitel 14). Abgewartet wurde das im Lab nicht.
]

#gelernt(
  [Geplante Wartung: drain, Controller mit `evict` abgeben, neu starten, warten bis `--faulty` leer ist, uncordon.],
  [Nach einem Absturz mit schnellem Neustart heilt sich alles selbst. Die meiste Zeit kostet der CSI-Treiber.],
  [Bleibt ein Node aus, hängt ein StatefulSet-Pod dauerhaft in `Terminating`.],
  [Das Out-of-Service-Taint ist die menschliche Bestätigung, dass ein Node tot ist. Danach läuft der Pod in Sekunden woanders.],
  [Ein Pod kann auf einem Node ohne Kopie landen. LINSTOR hängt das Volume dann diskless an.],
)
