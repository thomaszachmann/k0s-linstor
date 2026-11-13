#import "../lib.typ": *

#kapitel(
  [Überwachung: Was du messen und alarmieren solltest],
  ziel: [Du kennst die beiden Metrik-Quellen für LINSTOR und DRBD, baust Prometheus, Alertmanager, Grafana, Loki und Alloy im Lab auf und verfolgst einen echten DRBD-Fehler vom Kernel-Log bis zur Alarm-Mail.],
  zeit: [90 Minuten],
  braucht: [Den Cluster, Helm auf dem Mac und etwa 1,5 GiB freien Arbeitsspeicher über die drei Worker verteilt.],
)

Bis hierher hast du Zustände mit `linstor` und `drbdadm` von Hand gelesen. Im Betrieb schaut niemand alle paar Minuten nach. Dieses Kapitel baut deshalb einen kleinen, vollständigen Monitoring-Stack ins Lab und richtet ihn auf LINSTOR und DRBD aus. Danach trennst du absichtlich eine DRBD-Verbindung und siehst, was Metriken, Logs und Alarme daraus machen.

Der Stack ist bewusst auf einen Cluster zugeschnitten. Wie Prometheus, Alertmanager und Grafana für viele Cluster und lange Aufbewahrung zusammenspielen, beschreibt das Buch „Kubernetes beobachten“.

== Zwei Quellen

#tabelle(
  (auto, auto, 1fr),
  ([Quelle], [Endpunkt], [Was sie weiß]),
  [LINSTOR-Controller], [`http://10.10.0.100:3370/metrics`], [Den Soll-Zustand und das, was die Satellites melden: Nodes, Pools, Volumes, Fehlerberichte],
  [drbd-reactor], [`http://<node>:9942/metrics`], [Den Ist-Zustand von DRBD auf genau diesem Node: Verbindungen, Quorum, Rolle, Out-of-Sync, Suspend],
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
  [`drbd_resource_role`], [Primary oder Secondary. Entscheidet, ob ein Problem die Anwendung trifft.],
  [`drbd_peerdevice_outofsync_bytes`], [Ein Partner ist nicht auf Stand, etwa nach einem Node-Ausfall],
  [`drbd_device_unintentionaldiskless`], [Eine Kopie hat ihre Platte verloren (Kapitel 14)],
)

== Der Stack im Überblick

#tabelle(
  (auto, auto, 1fr),
  ([Baustein], [Läuft als], [Aufgabe]),
  [Prometheus 3.16], [StatefulSet, 1 Pod], [Sammelt Metriken ein, wertet Alarmregeln aus],
  [Alertmanager 0.35], [StatefulSet, 1 Pod], [Gruppiert Alarme und verschickt Mails],
  [Grafana 13.3], [Deployment], [Dashboards für Metriken und Logs],
  [node-exporter, kube-state-metrics], [DaemonSet, Deployment], [Host- und Kubernetes-Metriken],
  [Loki 3.6], [StatefulSet, 1 Pod], [Speichert Logs, durchsuchbar mit LogQL],
  [Alloy 1.21], [DaemonSet], [Liest Journal und Pod-Logs auf jedem Worker, schickt sie an Loki],
  [Mailpit 1.33], [Deployment], [Fängt die Alarm-Mails ab und zeigt sie im Browser],
)

Die ersten vier kommen gemeinsam aus dem Helm-Chart `kube-prometheus-stack` 93.2.2, Loki und Alloy aus den Charts von Grafana. Im Lab brauchte der ganze Stack nach dem Start etwa 1,35 GiB Arbeitsspeicher.

#falle[
  LINSTOR und DRBD laufen auf den Hosts, nicht als Pods. Ein ServiceMonitor findet sie deshalb nicht. Prometheus bekommt sie als statische Ziele. Die Witness `k0s-ctrl` ist außerdem kein Kubernetes-Node: Weder node-exporter noch Alloy laufen dort. Ihre DRBD-Metriken erreicht Prometheus über `172.16.0.176`, weil sie kein Storage-Netz hat.
]

== Prometheus, Alertmanager und Grafana

#datei("lab/monitoring/kube-prometheus-stack-values.yaml", raw(read("../../lab/monitoring/kube-prometheus-stack-values.yaml"), lang: "yaml", block: true))

Die Stellen, die für dieses Lab wichtig sind:

- *k0s-Controller-Komponenten aus.* k0s betreibt API-Server, Scheduler, Controller-Manager und etcd auf `k0s-ctrl` außerhalb des Clusters. Der API-Server ist über den Service `kubernetes` erreichbar, die anderen nicht. Ohne die Schalter oben stünden drei Ziele dauerhaft auf `down` und feuerten Alarme.
- *`…SelectorNilUsesHelmValues: false`.* Sonst sieht Prometheus nur Regeln und Monitore mit dem Label des Helm-Releases. So findet er auch die eigene `PrometheusRule` weiter unten.
- *Statische Ziele mit Labels.* `instance` trägt den Node-Namen statt `IP:Port`. In Alarmen und Dashboards steht dann `k0s-w2` und nicht `10.10.0.12:9942`. Die Labels `node` und `exported_node` brauchst du erst für das Community-Dashboard weiter unten.
- *Route `null` für `Watchdog`.* Der Chart bringt einen Alarm mit, der *immer* feuert. Er ist ein Totmannschalter für die Alarmkette: Kommt er bei einem externen Dienst nicht mehr an, ist Prometheus oder Alertmanager kaputt. Ins Postfach des Storage-Teams gehört er nicht.

#cmd("Mac")[```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
```][Einmalig.]

#datei("lab/monitoring/mailpit.yaml", raw(read("../../lab/monitoring/mailpit.yaml"), lang: "yaml", block: true), erklaerung: [Mailpit nimmt auf Port 1025 jede Mail an und zeigt sie auf Port 8025. In Produktion steht in `smtp_smarthost` dein Mailserver, oder du nimmst einen anderen Empfänger wie Teams, Slack oder PagerDuty.])

#cmd("Mac")[```bash
kubectl apply -f lab/monitoring/mailpit.yaml
helm install kps prometheus-community/kube-prometheus-stack --version 93.2.2 \
  -n monitoring -f lab/monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
```][Dauert im Lab etwa fünf Minuten. Die meiste Zeit geht für die Images und für das Anlegen des PVC drauf.]

#cmd("Mac")[```bash
kubectl -n monitoring get pvc
```][Prometheus speichert auf LINSTOR.]

#pruefe[
```
NAME                                         STATUS   CAPACITY   STORAGECLASS
prometheus-kps-...-prometheus-0              Bound    5Gi        linstor-replicated
```
]

#warum[
  Hier überwacht etwas den Speicher, auf dem es selbst liegt. Solange eine Kopie ein Quorum hat, schreibt Prometheus weiter, und genau das willst du sehen. Fällt die Ressource von Prometheus aber selbst aus, wird das Monitoring blind, wenn du es am dringendsten brauchst. In Produktion liegt das Monitoring deshalb auf lokalem Speicher, in einem anderen Cluster oder schickt zumindest seine Alarme über einen Weg, der nicht vom überwachten Speicher abhängt. Für ein Lab ist `linstor-replicated` in Ordnung und zeigt nebenbei, dass die StorageClass trägt.
]

Für den Zugriff vom Mac reichen Port-Forwards:

#cmd("Mac")[```bash
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090 &
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-alertmanager 9093 &
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
kubectl -n monitoring port-forward svc/mailpit 8025 &
```][Prometheus unter `localhost:9090`, Alertmanager unter `:9093`, Grafana unter `:3000` (Benutzer `admin`, Passwort aus der Values-Datei), Mailpit unter `:8025`.]

Unter *Status → Target health* zeigt Prometheus, ob er alle Ziele erreicht:

#bild("bilder/17-prometheus-targets.jpg", [Die vier drbd-reactor-Instanzen und der LINSTOR-Controller hinter der VIP sind `UP`. Die Witness `k0s-ctrl` wird über das Management-Netz abgefragt.])

== Logs mit Loki und Alloy

Metriken sagen dir, *dass* etwas nicht stimmt. Warum, steht meist im Log: im Journal von `linstor-satellite` und `drbd-reactor` und vor allem in den Kernelmeldungen von DRBD. Loki speichert diese Logs, Alloy sammelt sie ein.

#datei("lab/monitoring/loki-values.yaml", raw(read("../../lab/monitoring/loki-values.yaml"), lang: "yaml", block: true), erklaerung: [Ein einziger Loki-Pod mit Dateisystem-Speicher auf einem LINSTOR-PVC. Die Caches und das Gateway des Charts sind für ein Lab überdimensioniert und deshalb aus.])

#datei("lab/monitoring/alloy-values.yaml", raw(read("../../lab/monitoring/alloy-values.yaml"), lang: "yaml", block: true), erklaerung: [Zwei Quellen. `loki.source.journal` liest das Journal des Hosts und macht aus den Journal-Feldern die Labels `unit`, `node` und `transport`. DRBD schreibt in den Kernel-Ring-Buffer, diese Zeilen haben `transport="kernel"`. `loki.source.kubernetes` holt die Pod-Logs über die Kubernetes-API. Der Selektor auf `NODE_NAME` sorgt dafür, dass jeder Alloy-Pod nur die Pods seines eigenen Nodes liest.])

#cmd("Mac")[```bash
helm install loki grafana/loki --version 7.6.0 \
  -n monitoring -f lab/monitoring/loki-values.yaml --wait --timeout 10m
helm install alloy grafana/alloy --version 1.15.0 \
  -n monitoring -f lab/monitoring/alloy-values.yaml --wait --timeout 5m
```][Grafana kennt Loki schon, die Datenquelle steht unter `additionalDataSources` in den Values von kube-prometheus-stack.]

#cmd("Mac")[```bash
kubectl -n monitoring port-forward svc/loki 3100 &
curl -s localhost:3100/loki/api/v1/label/unit/values
```][Welche systemd-Units bei Loki angekommen sind.]

#pruefe[
```
{"status":"success","data":["ModemManager.service", ..., "drbd-reactor.service",
 ..., "k0sworker.service","linstor-controller.service","linstor-satellite.service", ...]}
```
]

In Grafana suchst du Logs unter *Explore* mit der Datenquelle *Loki*. Eine Abfrage für alle Zustandswechsel von DRBD:

#datei("LogQL", ```
{job="journal", transport="kernel"} |= "drbd" |~ "conn\\(|quorum|susp"
```, erklaerung: [Der Teil in geschweiften Klammern wählt die Log-Ströme über Labels aus und ist schnell. `|=` filtert auf einen festen Text, `|~` auf einen regulären Ausdruck. Diese Filter durchsuchen den Text und sind langsamer, deshalb immer erst mit Labels eingrenzen.])

#falle[
  Im Journal des Controllers steht bei jedem Scrape eine Zeile `REST/API RestClient(...; 'Prometheus/3.16.0')/metrics` und dazu `Assembled error reports`. Bei einem Scrape alle 30 Sekunden verdrängen diese Zeilen alles andere. Das Dashboard unten filtert sie mit `!~ "REST/API|/metrics|Assembled error reports"` heraus.
]

== Alarmregeln

#datei("lab/monitoring/linstor-alerts.yaml", raw(read("../../lab/monitoring/linstor-alerts.yaml"), lang: "yaml", block: true))

Die Werte für `for` sind bewusst gewählt:

- `DrbdVerbindungGetrennt` wartet 5 Minuten. Ein Neustart eines Nodes dauert etwa 30 Sekunden (Kapitel 10) und soll niemanden wecken.
- `DrbdOhneQuorum` und `DrbdSuspendiert` warten nur 1 Minute. In diesem Zustand steht die Anwendung. Beide gelten nur dort, wo die Ressource Primary ist. Warum, zeigt der Versuch weiter unten.
- `DrbdOutOfSync` wartet 30 Minuten. Ein Resync nach einem Neustart ist normal, ein Resync, der nicht fertig wird, nicht.

Der Prometheus-Operator liest Regeln aus Objekten vom Typ `PrometheusRule`. Die Datei oben ist eine gewöhnliche Regeldatei, damit `promtool` sie direkt prüfen kann. Für den Cluster wird sie in das Objekt eingepackt:

#cmd("Mac")[```bash
{ printf 'apiVersion: monitoring.coreos.com/v1\nkind: PrometheusRule\n'
  printf 'metadata:\n  name: linstor-drbd\n  namespace: monitoring\nspec:\n'
  sed 's/^/  /' lab/monitoring/linstor-alerts.yaml; } | kubectl apply -f -
```][Eine Quelle für beides: Der Test prüft genau die Regeln, die im Cluster laufen. Nach etwa einer Minute stehen sie unter *Alerts* in Prometheus.]

== Die Regeln testen

`promtool` prüft Regeln auf Syntax und spielt Testfälle mit erfundenen Zeitreihen durch. Ein Ausschnitt des Tests:

#datei("lab/monitoring/linstor-alerts-test.yaml (Ausschnitt)", ```yaml
    input_series:
      - series: 'drbd_connection_state{name="pvc-a",conn_name="k0s-w3",drbd_connection_state="StandAlone"}'
        values: '0 0 1x10'
      # Im Lab beobachtet: Der getrennte Secondary verliert das Quorum,
      # die Anwendung auf dem Primary läuft weiter. Kein Alarm.
      - series: 'drbd_device_quorum{name="pvc-b",instance="k0s-w2"}'
        values: '1 1 0x5'
      - series: 'drbd_resource_role{name="pvc-b",instance="k0s-w2",drbd_resource_role="Primary"}'
        values: '0x8'
    alert_rule_test:
      - eval_time: 9m
        alertname: DrbdVerbindungGetrennt
        exp_alerts:
          - exp_labels: {severity: critical, name: pvc-a, conn_name: k0s-w3, drbd_connection_state: StandAlone}
```, erklaerung: [Ab Minute 2 ist die Verbindung `StandAlone`. Nach 5 Minuten, bei Minute 9 also sicher, muss der Alarm feuern. Weitere Fälle prüfen Quorum-Verlust auf einem Primary (`pvc-a`, Alarm) und auf einem Secondary (`pvc-b`, kein Alarm) sowie einen Pool mit 10 % frei. Der disklose Pool mit Gesamtgröße 0 darf dabei keinen Alarm auslösen.])

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
Checking linstor-alerts.yaml
  SUCCESS: 7 rules found

  SUCCESS
```
]

== Das Dashboard

Für den täglichen Blick auf LINSTOR und DRBD liegt ein eigenes Dashboard im Repository: `lab/monitoring/linstor-dashboard.json`. Grafana lädt es über den Dashboard-Sidecar aus jeder ConfigMap mit dem Label `grafana_dashboard`:

#cmd("Mac")[```bash
kubectl -n monitoring create configmap linstor-dashboard \
  --from-file=lab/monitoring/linstor-dashboard.json
kubectl -n monitoring label configmap linstor-dashboard grafana_dashboard=1
```][Nach etwa 30 Sekunden steht es unter *Dashboards* als „LINSTOR und DRBD“. Änderungen an der Datei spielst du genauso ein, mit `--dry-run=client -o yaml | kubectl apply -f -`.]

#bild("bilder/17-dashboard-gesund.jpg", [Das Dashboard im Normalzustand. Die Spitzen bei Out-of-Sync um 16:15 sind die Erstsynchronisation der gerade angelegten PVCs von Prometheus und Loki, kein Fehler.])

Die sechs Panels beantworten die Fragen aus den Betriebskapiteln:

#tabelle(
  (auto, 1fr),
  ([Panel], [Frage]),
  [LINSTOR-Nodes], [Sind alle Satellites ONLINE? (Kapitel 10, 15)],
  [ohne Quorum / suspendiert / getrennt], [Hängt gerade irgendwo eine Anwendung? Alles außer 0 ist rot.],
  [Freier Platz], [Wann wird ein Pool knapp? Rot unter 15 % (Kapitel 12)],
  [Out-of-Sync], [Läuft ein Resync, und wird er fertig?],
  [Verbindungen aufgebaut?], [Eine Zeile je Ressource. Rot, sobald *irgendeine* Verbindung fehlt.],
  [Logs], [Was LINSTOR und drbd-reactor dazu sagen],
)

#falle[
  Die PVC-Namen sind 40 Zeichen lang. In Legenden passen sie nicht. Das Dashboard kürzt sie mit `label_replace(..., "name", "$1", "name", "(pvc-[0-9a-f]{8}).*")` auf die ersten acht Stellen. Das reicht, um sie in `linstor resource list` wiederzufinden.
]

== Fertige Dashboards

Zu kube-prometheus-stack gehören gut zwei Dutzend Dashboards. Für dieses Buch sind zwei interessant: „Node Exporter / Nodes“ für CPU, Speicher und Platten der Worker und „Kubernetes / Persistent Volumes“ für die Belegung der PVCs aus Sicht von Kubernetes.

#bild("bilder/17-node-exporter.jpg", [„Node Exporter / Nodes“ für `k0s-w2`. Die Geräte `dm-*` unter *Disk I/O* sind die LVM-Volumes, auf denen DRBD liegt.])

Ein eigenes Dashboard für k0s gibt es nicht. Die Kubernetes-Dashboards funktionieren, nur die für Scheduler, Controller-Manager und etcd bleiben leer, weil diese Komponenten nicht abgefragt werden.

Für LINSTOR und DRBD gibt es auf grafana.com das Dashboard 15917 „LINSTOR / DRBD“ vom Piraeus-Projekt. Es ist für das Label-Schema des Piraeus-Operators gebaut: DRBD-Metriken mit `node`, LINSTOR-Metriken mit `exported_node`. Deshalb stehen in den Values oben die zusätzlichen Labels an den drbd-reactor-Zielen und die Regel unter `metric_relabel_configs` für den Controller.

#cmd("Mac")[```bash
curl -sL https://grafana.com/api/dashboards/15917/revisions/latest/download \
  | sed 's/${ds_prometheus}/prometheus/g' > lab/monitoring/dashboard-15917-linstor-drbd.json
kubectl -n monitoring create configmap dashboard-15917 \
  --from-file=lab/monitoring/dashboard-15917-linstor-drbd.json
kubectl -n monitoring label configmap dashboard-15917 grafana_dashboard=1
```][Der Sidecar löst Platzhalter für Datenquellen nicht auf. `sed` ersetzt sie durch die UID der Prometheus-Datenquelle.]

#bild("bilder/17-dashboard-15917.jpg", [Dashboard 15917 mit den angepassten Labels. „Scrape Duration“ und „New Error Reports“ bleiben leer, weil sie Metriken erwarten, die nur der Piraeus-Operator erzeugt.])

#warum[
  Ein Community-Dashboard ist ein guter Startpunkt, aber kein Vertrag. Es passt zu der Umgebung, in der es gebaut wurde. Prüfe nach dem Import jedes Panel: Ein leeres Panel ist harmlos, ein Panel, das falsch filtert und deshalb grün zeigt, ist es nicht.
]

== Ein Alarm von Anfang bis Ende

Jetzt wird es ernst. Auf `k0s-w2` trennst du die DRBD-Verbindung der Postgres-Ressource aus Kapitel 8 zu `k0s-w3`. Postgres läuft auf `k0s-w3`, dort ist die Ressource Primary.

#cmd("k0s-w2")[```bash
sudo drbdadm disconnect pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250:k0s-w3
sudo drbdadm status pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250
```][Nur diese eine Verbindung. LINSTOR baut sie nicht von selbst wieder auf.]

#pruefe[
```
pvc-55d1f760-... role:Secondary suspended:quorum
  disk:Outdated quorum:no open:no blocked:upper
  k0s-ctrl role:Secondary
    peer-disk:Diskless peer-client:yes
  k0s-w3 connection:StandAlone
```
]

Beim Trennen markiert DRBD die Kopie auf `k0s-w2` über einen clusterweiten Zustandswechsel als `Outdated`. Die Witness reicht die Nachricht weiter. Eine Kopie, die weiß, dass es irgendwo neuere Daten gibt, bekommt kein Quorum, auch wenn sie die Witness noch sieht (Kapitel 11). `k0s-w2` hält deshalb Schreibvorgänge an. Auf `k0s-w3` dagegen bleibt alles beim Alten: Primary, `UpToDate`, Quorum über die Witness. Postgres schreibt weiter, und jeder geschriebene Block landet als Out-of-Sync für `k0s-w2` in der Bitmap.

#cmd("Mac")[```bash
kubectl -n demo exec pg-0 -- psql -U postgres -c \
  "create table last(x text); insert into last select repeat(md5(random()::text),30) from generate_series(1,200000);"
```][Etwa 200 MB Schreiblast, damit Out-of-Sync sichtbar wächst.]

Der Ablauf im Lab, aus `lab/protokolle/17-alarm.log` und den Zeitstempeln von Prometheus und Mailpit:

#tabelle(
  (auto, 1fr),
  ([Uhrzeit], [Ereignis]),
  [16:22:59], [`drbdadm disconnect` auf `k0s-w2`],
  [16:23:00], [Kernel auf beiden Seiten: `conn( Connected -> Disconnecting )`, auf `k0s-w2` `quorum( yes -> no )`],
  [16:23:18], [`DrbdVerbindungGetrennt` für `k0s-w3` → `k0s-w2` (`Connecting`) wird *pending*],
  [16:23:48], [Dieselbe Regel für die Gegenrichtung (`StandAlone`), dazu `DrbdOhneQuorum`, `DrbdSuspendiert` und `DrbdOutOfSync`: *pending*],
  [16:25:18], [Mails zu `DrbdOhneQuorum` und `DrbdSuspendiert`: 1 Minute `for` plus 30 Sekunden `group_wait`],
  [16:28:48], [Mail zu `DrbdVerbindungGetrennt` mit beiden Richtungen in *einer* Mail],
  [16:31:43], [`drbdadm connect` auf `k0s-w2`, Resync von etwa 410 MiB],
  [16:32:10], [beide Seiten wieder `UpToDate`],
  [16:33:48, 16:35:18], [Mails mit `[RESOLVED]`],
)

`DrbdOutOfSync` wurde nie zugestellt. Der Resync war nach weniger als 30 Sekunden fertig, lange vor den 30 Minuten `for`. Genau so soll es sein.

=== Prometheus: pending

#bild("bilder/17-alerts-pending.jpg", [Prometheus unter *Alerts* kurz nach der Trennung. Die Bedingungen sind erfüllt, aber die Zeit in `for` ist noch nicht um.])

Ein Alarm hat drei Zustände. *Inactive*: Der Ausdruck liefert nichts. *Pending*: Er liefert etwas, aber kürzer als `for`. *Firing*: länger als `for`. Erst dann geht er an Alertmanager. Bei einem Node-Neustart von 30 Sekunden siehst du hier kurz *pending* und dann wieder *inactive*, und niemand wird geweckt.

=== Grafana: was ist los?

#bild("bilder/17-dashboard-stoerung.jpg", [Dasselbe Dashboard während der Störung. Oben rechts drei rote Kacheln, in der Zeitleiste ist `pvc-55d1f760` ab 16:23 rot, die Out-of-Sync-Kurve steigt auf etwa 410 MiB.])

Die LINSTOR-Nodes bleiben grün. Aus Sicht des Controllers ist jeder Satellite erreichbar. Dass eine einzelne DRBD-Verbindung fehlt, weiß nur drbd-reactor. Das ist der Grund für zwei Quellen.

=== Loki: warum?

#bild("bilder/17-loki-explore.jpg", [Explore mit der LogQL-Abfrage von oben. Die Kernelmeldungen beider Nodes zeigen die Trennung, `quorum( yes -> no )` und `susp-io( no -> quorum )` auf `k0s-w2`.])

Die Zeile `drbd1001: disk( UpToDate -> Outdated ) quorum( yes -> no )` erklärt beide Quorum-Alarme. Auf einem Node, auf dem DRBD-Meldungen nicht im Journal ankommen, sähest du hier nichts. Prüfe deshalb einmal mit einer harmlosen Aktion, dass die Kernelzeilen wirklich in Loki landen, bevor du dich im Ernstfall darauf verlässt.

=== Alertmanager und Mail

#bild("bilder/17-alertmanager.jpg", [Alertmanager gruppiert nach `alertname` und `name`. Die beiden Richtungen der getrennten Verbindung sind *eine* Gruppe mit zwei Alarmen.])

#bild("bilder/17-mailpit-firing.jpg", [Die Mail zu `DrbdVerbindungGetrennt` in Mailpit. Labels und Annotationen aus der Regel stehen im Text, `summary` nennt Ressource und Partner.])

`group_by: [alertname, name]` in den Values bündelt alles, was zu einer Ressource und einer Ursache gehört. Ohne Gruppierung kämen bei einem Node-Ausfall eine Mail je Ressource und Richtung. Bei 50 Volumes sind das 100 Mails in derselben Minute.

#cmd("k0s-w2")[```bash
sudo drbdadm connect pvc-55d1f760-7f7b-4d71-8a03-0e1e8cd11250:k0s-w3
```][Verbindung wiederherstellen. DRBD gleicht nur die Blöcke aus der Bitmap ab, nicht das ganze Volume.]

#bild("bilder/17-mailpit-inbox.jpg", [Der Posteingang nach dem Versuch. Jede Gruppe meldet sich einmal mit `FIRING` und einmal mit `RESOLVED`.])

Die Entwarnung kommt nicht sofort, sondern nach bis zu `group_interval` (5 Minuten). So entsteht bei einer flatternden Verbindung keine Mailflut.

== Was der Versuch über die Regeln lehrt

In der ersten Fassung lauteten die beiden Regeln einfach `drbd_device_quorum == 0` und `drbd_resource_suspended == 1`. Im Versuch feuerten sie beide als `critical`, für `k0s-w2`. Dort ist die Ressource aber Secondary und nicht geöffnet. Die Anwendung lief auf `k0s-w3` die ganze Zeit weiter. Die Beschreibung „die Anwendung steht“ war also falsch.

Die Verbindung zur Rolle stellt `and on (name, instance)` her:

#datei("PromQL", ```
drbd_device_quorum == 0
  and on (name, instance) drbd_resource_role{drbd_resource_role="Primary"} == 1
```, erklaerung: [`and` behält nur die Zeitreihen links, zu denen es rechts eine mit denselben Werten für `name` und `instance` gibt. Übrig bleiben Geräte ohne Quorum auf dem Node, auf dem die Ressource Primary ist. Der getrennte Secondary meldet sich trotzdem, über `DrbdVerbindungGetrennt` mit 5 Minuten Geduld.])

Der Fall steht jetzt als `pvc-b` im Test. Wer die Regel später vereinfacht, merkt es an `promtool test rules`.

#warum[
  Ein Alarm, der `critical` sagt und sich als harmlos herausstellt, kostet beim nächsten Mal Vertrauen. Ein solcher Versuch im Lab ist die billigste Stelle, solche Regeln zu finden. Die Screenshots oben zeigen noch die alte Fassung.
]

#hinweis("Wann Thanos oder Mimir?", akzent, akzent-hell)[
  Ein Prometheus mit 7 Tagen Aufbewahrung reicht für einen Cluster. Thanos oder Mimir lohnen sich, wenn du eine gemeinsame Sicht über mehrere Cluster brauchst, Metriken über Monate behalten willst oder zwei Prometheus-Instanzen als HA-Paar deduplizieren musst. Beide legen die Daten in Objektspeicher ab. Den hätte das Lab mit SeaweedFS aus Kapitel 13 sogar, aber Sidecar, Query, Store und Compactor kosten mehr Speicher, als die drei Worker übrig haben. Der Aufbau steht in „Kubernetes beobachten“.
]

== Aufräumen

Der Stack kann im Lab bleiben, die folgenden Kapitel stören sich nicht daran. Wenn du den Speicher brauchst:

#cmd("Mac")[```bash
helm -n monitoring uninstall alloy loki kps
kubectl delete namespace monitoring
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete
```][Der Namespace nimmt die PVCs mit, LINSTOR löscht die Ressourcen dank `reclaimPolicy: Delete`. Die CRDs bleiben bei `helm uninstall` stehen und müssen von Hand weg.]

#gelernt(
  [Der Controller liefert LINSTOR-Metriken über die VIP, drbd-reactor DRBD-Metriken auf jedem Node, auch auf der Witness.],
  [Dienste auf den Hosts kommen als statische Ziele zu Prometheus, mit `instance` als lesbarem Node-Namen.],
  [Alloy liest Journal und Kernelmeldungen, Loki macht sie mit LogQL durchsuchbar. Die Ursache eines DRBD-Alarms steht im Kernel-Log.],
  [`for`, `group_by` und `group_interval` entscheiden, ob ein Alarm hilft oder nervt.],
  [Quorum-Verlust und Suspend sind nur auf dem Primary kritisch. Erst der Versuch im Lab hat das gezeigt.],
  [Community-Dashboards setzen ein Label-Schema voraus. Passe die Scrape-Konfiguration an und prüfe jedes Panel.],
)
