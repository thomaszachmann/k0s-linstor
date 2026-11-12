#import "../lib.typ": *

#kapitel(
  [Überwachung: Was du messen und alarmieren solltest],
  ziel: [Du kennst die beiden Metrik-Quellen für LINSTOR und DRBD, weißt, welche Werte im Betrieb zählen, und hast getestete Alarmregeln für die Fehlerbilder aus den Kapiteln 10 bis 15.],
  zeit: [30 Minuten],
  braucht: [Den Cluster. Für Dashboards und Alarm-Zustellung ein Prometheus, wie ihn „Kubernetes beobachten“ aufbaut.],
)

Dieses Kapitel baut keinen Monitoring-Stack auf. Wie Prometheus, Alertmanager und Grafana für mehrere Cluster zusammenspielen, beschreibt das Buch „Kubernetes beobachten“. Hier geht es darum, *was* du von LINSTOR und DRBD einsammelst und worauf du alarmierst.

== Zwei Quellen

#tabelle(
  (auto, auto, 1fr),
  ([Quelle], [Endpunkt], [Was sie weiß]),
  [LINSTOR-Controller], [`http://10.10.0.100:3370/metrics`], [Den Soll-Zustand und das, was die Satellites melden: Nodes, Pools, Volumes, Fehlerberichte],
  [drbd-reactor], [`http://<node>:9942/metrics`], [Den Ist-Zustand von DRBD auf genau diesem Node: Verbindungen, Quorum, Out-of-Sync, Suspend],
)

Wie in Kapitel 9 gilt: Der Controller kann veraltet sein, DRBD auf dem Node nicht. Deshalb brauchst du beide.

== LINSTOR-Metriken

Der Controller liefert sie ohne weitere Einrichtung:

#cmd("k0s-w2")[```bash
curl -s http://10.10.0.100:3370/metrics | grep -oE "^linstor_[a-z_]+" | sort -u
```][Alle LINSTOR-Metriken. Dazu kommen die üblichen JVM-Werte.]

Die wichtigsten:

#tabelle(
  (auto, 1fr),
  ([Metrik], [Bedeutung]),
  [`linstor_node_state`], [`2` = ONLINE, `0` = OFFLINE, `3` = VERSION_MISMATCH (Kapitel 15)],
  [`linstor_volume_state`], [`1` = UpToDate, `4` = Diskless, `5` = Inconsistent, `6` = Failed],
  [`linstor_storage_pool_capacity_free_bytes`], [Freier Platz je Pool und Node, auch für `pool_nvme`],
  [`linstor_storage_pool_capacity_total_bytes`], [Gesamtgröße. Bei disklosen Pools 0.],
  [`linstor_error_reports_count`], [Anzahl der Fehlerberichte],
)

Die Zahlencodes erklärt der Endpunkt selbst in seinen `# HELP`-Zeilen:

#cmd("k0s-w2")[```bash
curl -s http://10.10.0.100:3370/metrics | grep "^# HELP linstor_node_state"
```][Die Bedeutung der Zustandswerte.]

#pruefe[
```
# HELP linstor_node_state 0="OFFLINE", 1="CONNECTED", 2="ONLINE", 3="VERSION_MISMATCH",
  4="FULL_SYNC_FAILED", 5="AUTHENTICATION_ERROR", 6="UNKNOWN", ...
```
]

#falle[
  Der Endpunkt hängt an der VIP und damit am Storage-Netz. Ein Prometheus, der das Storage-Netz nicht erreicht, bekommt keine LINSTOR-Metriken. Bei einem Failover des Controllers fehlen sie für die Dauer des Wechsels, etwa 15 bis 40 Sekunden (Kapitel 6 und 10). Ein Alarm auf `up == 0` für dieses Ziel braucht deshalb ein `for` von einigen Minuten.
]

== DRBD-Metriken mit drbd-reactor

drbd-reactor läuft auf den Controller-Kandidaten schon für die HA. Er hat ein Plugin, das DRBD-Zustände als Prometheus-Metriken ausgibt. Es braucht nur eine Konfigurationsdatei, und zwar auf *allen* Nodes mit DRBD, auch der Witness. Auf `k0s-ctrl` lief drbd-reactor bisher ohne Konfiguration.

#datei("lab/monitoring/prometheus.toml", raw(read("../../lab/monitoring/prometheus.toml"), lang: "toml", block: true), erklaerung: [`enums = true` gibt Zustände als eigene Zeitreihen je möglichem Wert aus, mit 1 für den aktuellen und 0 für alle anderen. Das lässt sich in PromQL einfach filtern.])

#cmd("Mac")[```bash
scp lab/monitoring/prometheus.toml k0s-w1:/tmp/
ssh k0s-w1 'sudo install -m 644 /tmp/prometheus.toml /etc/drbd-reactor.d/'
ssh k0s-w1 'sudo systemctl reload drbd-reactor'
```][Für alle vier Nodes. `reload` liest die neue Datei, ohne den Promoter für `linstor_db` zu stören.]

#cmd("k0s-w2")[```bash
curl -s localhost:9942/metrics | grep -E "^drbd_(device_quorum|resource_suspended)"
```][Zwei der wichtigsten Werte.]

#pruefe[
```
drbd_device_quorum{name="pvc-55d1f760-...",volume="0",minor="1001"} 1
drbd_device_quorum{name="linstor_db",volume="0",minor="1000"} 1
drbd_resource_suspended{name="pvc-55d1f760-..."} 0
drbd_resource_suspended{name="linstor_db"} 0
```
]

#tabelle(
  (auto, 1fr),
  ([Metrik], [Bezug zu den Betriebskapiteln]),
  [`drbd_connection_state{drbd_connection_state="StandAlone"}`], [Split-Brain (Kapitel 11, Versuch E)],
  [`drbd_device_quorum`], [Quorum-Verlust (Kapitel 11, Versuch C)],
  [`drbd_resource_suspended`], [Angehaltene Schreibvorgänge, die Anwendung hängt],
  [`drbd_peerdevice_outofsync_bytes`], [Ein Partner ist nicht auf Stand, etwa nach einem Node-Ausfall],
  [`drbd_device_unintentionaldiskless`], [Eine Kopie hat ihre Platte verloren (Kapitel 14)],
)

== Alarmregeln

#datei("lab/monitoring/linstor-alerts.yaml", raw(read("../../lab/monitoring/linstor-alerts.yaml"), lang: "yaml", block: true))

Die Werte für `for` sind bewusst gewählt:

- `DrbdVerbindungGetrennt` wartet 5 Minuten. Ein Neustart eines Nodes dauert etwa 30 Sekunden (Kapitel 10) und soll niemanden wecken.
- `DrbdOhneQuorum` und `DrbdSuspendiert` warten nur 1 Minute. In diesem Zustand steht die Anwendung.
- `DrbdOutOfSync` wartet 30 Minuten. Ein Resync nach einem Neustart ist normal, ein Resync, der nicht fertig wird, nicht.

== Die Regeln testen

`promtool` prüft Regeln auf Syntax und spielt Testfälle mit erfundenen Zeitreihen durch. Der Test für drei der Alarme:

#datei("lab/monitoring/linstor-alerts-test.yaml (Ausschnitt)", ```yaml
    input_series:
      - series: 'drbd_connection_state{name="pvc-a",conn_name="k0s-w3",drbd_connection_state="StandAlone"}'
        values: '0 0 1x10'
    alert_rule_test:
      - eval_time: 9m
        alertname: DrbdVerbindungGetrennt
        exp_alerts:
          - exp_labels: {severity: critical, name: pvc-a, conn_name: k0s-w3, drbd_connection_state: StandAlone}
```, erklaerung: [Ab Minute 2 ist die Verbindung `StandAlone`. Nach 5 Minuten, bei Minute 9 also sicher, muss der Alarm feuern. Weitere Fälle prüfen Quorum-Verlust und einen Pool mit 10 % frei. Der disklose Pool mit Gesamtgröße 0 darf dabei keinen Alarm auslösen.])

#cmd("Mac")[```bash
kubectl create namespace promtool
kubectl -n promtool create configmap regeln \
  --from-file=lab/monitoring/linstor-alerts.yaml \
  --from-file=lab/monitoring/linstor-alerts-test.yaml
kubectl -n promtool run pt --rm -i --restart=Never \
  --image=quay.io/prometheus/prometheus:v3.15.1 --overrides='{"spec":{"containers":[{
    "name":"pt","image":"quay.io/prometheus/prometheus:v3.15.1",
    "command":["sh","-c","cd /r && promtool check rules linstor-alerts.yaml && promtool test rules linstor-alerts-test.yaml"],
    "volumeMounts":[{"name":"r","mountPath":"/r"}]}],
    "volumes":[{"name":"r","configMap":{"name":"regeln"}}]}}'
kubectl delete namespace promtool
```][Wer `promtool` lokal hat, ruft die beiden Befehle direkt auf. Im Lab läuft es in einem Pod mit dem Prometheus-Image.]

#pruefe[
```
  SUCCESS
```
]

== Was ein Dashboard zeigen sollte

Für den täglichen Blick reichen vier Panels:

+ Nodes nach `linstor_node_state`, alles außer ONLINE rot
+ Freier Platz je Pool und Node, getrennt nach `pool_data` und `pool_nvme`
+ Ressourcen mit `drbd_device_quorum == 0` oder `drbd_resource_suspended == 1`
+ `drbd_peerdevice_outofsync_bytes` über die Zeit

#hinweis("Nicht im Lab gebaut", warn, warn-hell)[
  Prometheus, Alertmanager und Grafana wurden für dieses Buch nicht im k0s-Lab installiert. Getestet sind die Endpunkte, die Metriknamen und Label aus den echten Ausgaben und die Alarmregeln mit `promtool`. Wie die Ziele per ServiceMonitor oder statischer Konfiguration eingesammelt werden, hängt vom vorhandenen Monitoring ab.
]

#gelernt(
  [Der Controller liefert LINSTOR-Metriken über die VIP, drbd-reactor DRBD-Metriken auf jedem Node.],
  [drbd-reactor braucht für die Metriken nur eine Datei mit `[[prometheus]]`.],
  [Die Zahlencodes erklären die `# HELP`-Zeilen des Endpunkts.],
  [Quorum-Verlust und Suspend sind sofort kritisch, getrennte Verbindungen erst nach einigen Minuten.],
  [Alarmregeln lassen sich mit `promtool test rules` prüfen, ohne dass etwas kaputtgehen muss.],
)
