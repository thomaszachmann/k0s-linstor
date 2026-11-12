#import "../lib.typ": *

#kapitel(
  [Piraeus als CSI-Treiber],
  ziel: [Kubernetes legt Volumes über den externen LINSTOR-Controller an. Der Piraeus-Operator liefert nur den CSI-Treiber, keine Satellites. Eine PostgreSQL-Datenbank läuft auf einem replizierten Volume und zieht ohne Datenverlust auf einen anderen Node um.],
  zeit: [45 Minuten],
  braucht: [Den Controller hinter der VIP aus Kapitel 6, `helm` auf dem Mac],
)

== Was der Operator hier tut und was nicht

Der Piraeus-Operator kann alles: Controller, Satellites, DRBD-Modul, CSI. Hier soll er nur eines tun: den CSI-Treiber bereitstellen, der mit dem LINSTOR auf den Hosts spricht.

#tabelle(
  (auto, auto, 1fr),
  ([Komponente des Operators], [Hier], [Warum]),
  [LINSTOR-Controller], [aus], [Läuft auf den Hosts, erreichbar über die VIP.],
  [Satellites], [aus], [Laufen auf den Hosts als systemd-Dienste.],
  [CSI-Controller und CSI-Node], [an], [Übersetzen PVCs in LINSTOR-Aufrufe und mounten die Volumes.],
  [HA-Controller], [aus], [Würde Pods bei DRBD-Problemen zwangsweise verschieben. Dieses Buch verzichtet bewusst darauf.],
  [Affinity-Controller], [aus], [Passt PV-Affinitäten an, wenn LINSTOR Replikate verschiebt. Nicht genutzt.],
  [NFS-Server], [aus], [Für ReadWriteMany-Volumes. Nicht genutzt.],
)

== Den Operator installieren

Das Helm-Chart des Operators liegt im Git-Repository des Projekts, nicht in einem Chart-Repository. Seine Version entspricht der Operator-Version.

#cmd("Mac")[```bash
git clone --depth 1 --branch v2.12.0 https://github.com/piraeusdatastore/piraeus-operator.git
helm install piraeus-operator piraeus-operator/charts/piraeus \
  --namespace piraeus-datastore --create-namespace --set installCRDs=true
kubectl -n piraeus-datastore rollout status deploy/piraeus-operator-controller-manager
```][`installCRDs=true` ist nötig. Der Standardwert `false` installiert den Operator ohne seine Ressourcen-Typen.]

#pruefe[
```
deployment "piraeus-operator-controller-manager" successfully rolled out
```
]

== Der Cluster als Helm-Werte

Die Ressource `LinstorCluster` beschreibt, was der Operator betreiben soll. Das Chart `linstor-cluster` erzeugt sie aus Helm-Werten.

#cmd("Mac")[```bash
helm repo add piraeus-charts https://piraeus.io/helm-charts/
helm repo update
```][Das Chart-Repository für `linstor-cluster`.]

Die Werte entstehen in diesem Kapitel Schritt für Schritt, weil jeder Schritt eine Falle offenlegt. Am Ende steht die vollständige Datei `lab/piraeus/linstor-cluster-values.yaml`.

=== Erster Versuch: externer Controller, keine Satellites

#datei("Erster Stand der Werte", ```yaml
linstorCluster:
  externalController:
    url: http://10.10.0.100:3370
  nodeSelector:
    piraeus.io/managed-satellite: "true"
  highAvailabilityController: {enabled: false}
  affinityController: {enabled: false}
  nfsServer: {enabled: false}
  csiController:
    podTemplate:
      spec:
        containers:
          - name: linstor-csi
            image: quay.io/piraeusdatastore/piraeus-csi:v1.12.0
  csiNode:
    podTemplate:
      spec:
        containers:
          - name: linstor-csi
            image: quay.io/piraeusdatastore/piraeus-csi:v1.12.0
```, erklaerung: [
  `externalController` zeigt auf die VIP. Der Operator startet dann keinen eigenen Controller.
  Der `nodeSelector` nennt ein Label, das kein Node trägt. Damit findet der Operator keinen Node für Satellites.
  Das CSI-Image ist auf v1.12.0 gepinnt. Der Operator 2.12 bringt v1.13.1 mit, und CSI ab 1.13 setzt LINSTOR 1.35 voraus. Mit LINSTOR 1.33 muss CSI auf 1.12 bleiben. In Kapitel 15 werden beide gemeinsam aktualisiert.
])

#cmd("Mac")[```bash
helm install linstor-cluster piraeus-charts/linstor-cluster --version 1.2.0 \
  -n piraeus-datastore -f werte.yaml
kubectl -n piraeus-datastore get pods
```][Installiert die Cluster-Beschreibung.]

#pruefe[
```
NAME                                                   READY   STATUS    RESTARTS   AGE
linstor-csi-controller-d58ff7b44-4vg29                 0/6     Pending   0          59s
piraeus-operator-controller-manager-54fd7c49f9-767dh   1/1     Running   0          100s
```
Der Controller ist erreichbar, aber der CSI-Controller hängt in `Pending`, und CSI-Node-Pods gibt es gar keine.
]

#falle[
  *Der `nodeSelector` gilt nicht nur für Satellites, sondern auch für alle CSI-Pods.* `kubectl describe` am Pod sagt: `3 node(s) didn't match Pod's node affinity/selector`. Im Quellcode des Operators sieht man, dass derselbe Selector auf Satellites, CSI-Controller, CSI-Node und weitere Komponenten angewendet wird.
]

Die Lösung: Den Selector in den Pod-Vorlagen der CSI-Komponenten wieder entfernen. Die `podTemplate` wird als Strategic-Merge-Patch angewendet. Darin löscht `null` einen Schlüssel:

#datei("Ergänzung für csiController und csiNode", ```yaml
    podTemplate:
      spec:
        nodeSelector:
          piraeus.io/managed-satellite: null
```)

=== Zweiter Versuch: der kubelet-Pfad von k0s

Nach dem Update laufen der CSI-Controller und drei CSI-Node-Pods an. Die Node-Pods bleiben aber in `Init:0/1` stehen.

#cmd("Mac")[```bash
kubectl -n piraeus-datastore describe pod -l app.kubernetes.io/component=linstor-csi-node | tail -3
```][Die Ereignisse eines CSI-Node-Pods.]

#pruefe[
```
Warning  FailedMount  ...  MountVolume.SetUp failed for volume "registration-dir" :
  hostPath type check failed: /var/lib/kubelet/plugins_registry is not a directory
```
]

#falle[
  k0s legt das kubelet unter `/var/lib/k0s/kubelet` ab (Kapitel 4). Der CSI-Treiber sucht es unter `/var/lib/kubelet`. Piraeus beschreibt die Korrektur in seiner Anleitung für k0s: drei Host-Pfade, ein zusätzlicher Mount und der Registrierungspfad.
]

#datei("Ergänzung für csiNode", ```yaml
        containers:
          - name: linstor-csi
            volumeMounts:
              - name: publish-dir
                mountPath: /var/lib/k0s/kubelet
                mountPropagation: Bidirectional
          - name: csi-node-driver-registrar
            env:
              - name: KUBELET_REGISTRATION_PATH
                value: /var/lib/k0s/kubelet/plugins/linstor.csi.linbit.com/csi.sock
        volumes:
          - name: publish-dir
            hostPath: {path: /var/lib/k0s/kubelet}
          - name: registration-dir
            hostPath: {path: /var/lib/k0s/kubelet/plugins_registry}
          - name: plugin-dir
            hostPath: {path: /var/lib/k0s/kubelet/plugins/linstor.csi.linbit.com}
```, erklaerung: [Der zusätzliche Mount unter `/var/lib/k0s/kubelet` muss im Container denselben Pfad haben wie auf dem Host. Der kubelet übergibt dem Treiber absolute Pfade, und die müssen im Container stimmen.])

=== Dritter Versuch: die Neustart-Schleife

Jetzt laufen die CSI-Node-Pods, aber nie lange. Alle paar Sekunden werden sie gelöscht und neu erzeugt.

#cmd("Mac")[```bash
kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-csi-node
kubectl get csinodes -o 'custom-columns=NODE:.metadata.name,DRIVERS:.spec.drivers[*].name'
```][Alter der Pods und welche Nodes den Treiber registriert haben.]

#pruefe[
```
NAME                     READY   STATUS            RESTARTS   AGE
linstor-csi-node-5n4fm   0/3     PodInitializing   0          2s
linstor-csi-node-8wgdg   0/3     PodInitializing   0          1s
linstor-csi-node-98gms   3/3     Running           0          3s
NODE     DRIVERS
k0s-w1   <none>
k0s-w2   linstor.csi.linbit.com
k0s-w3   <none>
```
Keine Abstürze, keine Fehler in den Logs. Die Ereignisse zeigen nur `Killing`.
]

Der Grund steht im Quellcode des Operators. Für jeden CSI-Node vergleicht er die Topologie-Schlüssel, die der Treiber in Kubernetes meldet, mit den Eigenschaften `Aux/topology/*` des passenden LINSTOR-Nodes. Weichen sie ab, löscht er den Pod, damit der Treiber sich neu registriert. Für Nodes, die der Operator selbst verwaltet, setzt er diese Eigenschaften selbst. Unsere Nodes verwaltet er nicht.

Der Treiber meldet den Schlüssel `linbit.com/hostname`. Den bekommen die LINSTOR-Nodes von Hand:

#cmd("k0s-w1")[```bash
linstor node set-property k0s-w1 Aux/topology/linbit.com/hostname k0s-w1
linstor node set-property k0s-w2 Aux/topology/linbit.com/hostname k0s-w2
linstor node set-property k0s-w3 Aux/topology/linbit.com/hostname k0s-w3
```][Der Wert ist der Node-Name. Die Witness bekommt keinen Eintrag, auf ihr läuft kein CSI-Node.]

#pruefe[
```
NAME                     READY   STATUS    RESTARTS   AGE
linstor-csi-node-8t9g8   3/3     Running   0          93s
linstor-csi-node-lfwd7   3/3     Running   0          92s
linstor-csi-node-x6m4r   3/3     Running   0          93s
NODE     DRIVERS                  KEYS
k0s-w1   linstor.csi.linbit.com   [linbit.com/hostname]
k0s-w2   linstor.csi.linbit.com   [linbit.com/hostname]
k0s-w3   linstor.csi.linbit.com   [linbit.com/hostname]
```
]

#falle[
  Diese Eigenschaft gehört in die Automatisierung, die neue Nodes in LINSTOR anlegt. Ein neuer Worker ohne sie bringt sofort wieder die Neustart-Schleife, und zwar nur auf diesem einen Node.
]

=== Die vollständigen Werte

#datei("lab/piraeus/linstor-cluster-values-linstor-1.33.yaml", raw(read("../../lab/piraeus/linstor-cluster-values-linstor-1.33.yaml"), lang: "yaml", block: true), erklaerung: [Alle drei Korrekturen zusammen.])

#cmd("Mac")[```bash
helm upgrade linstor-cluster piraeus-charts/linstor-cluster --version 1.2.0 \
  -n piraeus-datastore -f lab/piraeus/linstor-cluster-values-linstor-1.33.yaml
kubectl get linstorcluster -o \
  jsonpath='{range .items[].status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```][Prüft den Zustand der Cluster-Beschreibung.]

#pruefe[
```
Applied=True Resources applied
Available=True Controller 1.33.3 (API: 1.27.0, Git: 1ff3a1ea...) reachable at 'http://10.10.0.100:3370'
Configured=True Properties applied
```
]

=== Was der Operator am Controller verändert

`Configured=True Properties applied` ist wörtlich gemeint. Der Operator schreibt eigene Einstellungen in den externen Controller:

#cmd("k0s-w1")[```bash
linstor controller list-properties | grep -E "piraeus|DrbdOptions"
```][Die globalen Eigenschaften des Controllers.]

#pruefe[
```
│ Aux/piraeus.io/managed-by                          │ piraeus-operator │
│ DrbdOptions/AutoEvictAllowEviction                 │ false            │
│ DrbdOptions/Net/rr-conflict                        │ retry-connect    │
│ DrbdOptions/Resource/on-no-data-accessible         │ suspend-io       │
│ DrbdOptions/Resource/on-no-quorum                  │ suspend-io       │
│ DrbdOptions/Resource/on-suspended-primary-outdated │ force-secondary  │
```
`Aux/piraeus.io/last-applied` listet, welche davon vom Operator stammen.
]

#falle[
  Diese Werte gelten für *alle* Ressourcen des Controllers, auch für solche außerhalb von Kubernetes. Wichtig ist vor allem `AutoEvictAllowEviction=false`: Die automatische Evakuierung ausgefallener Nodes ist damit abgeschaltet (Kapitel 10). Wer am Controller etwas anderes einstellen will, muss es über `linstorCluster.properties` in den Helm-Werten tun. Sonst setzt der Operator es beim nächsten Abgleich zurück. Im Lab war ein von Hand gesetztes `true` nach spätestens zwei Minuten wieder `false`.
]

== Die StorageClass

#datei("lab/k8s/storageclass.yaml", raw(read("../../lab/k8s/storageclass.yaml"), lang: "yaml", block: true), erklaerung: [
  `WaitForFirstConsumer` legt das Volume erst an, wenn klar ist, auf welchem Node der Pod landet. LINSTOR kann dann eine Kopie direkt dort platzieren.
  Die `property.linstor.csi.linbit.com/`-Parameter werden zu Eigenschaften der Resource-Group.
])

#falle[
  Im ersten Versuch stand in der StorageClass nur `resourceGroup: rg-k8s`, in der Annahme, die Vorlage aus Kapitel 7 liefere den Rest. Das Ergebnis war ein Volume mit *einem* Replikat ohne Writecache, und `rg-k8s` war danach umgeschrieben:
  ```
  │ rg-k8s │ PlaceCount: 1                     │ ...
  │        │ LayerStack: ['DRBD', 'STORAGE']   │ ...
  ```
  Der CSI-Treiber schreibt bei jedem neuen Volume die Parameter der StorageClass in die Resource-Group. Was fehlt, setzt er auf seine Standardwerte. *Die StorageClass ist die Quelle der Wahrheit*, nicht die Resource-Group. Prüfe nach jeder neuen StorageClass mit `linstor resource-group list`, was wirklich gilt.
]

== Eine Datenbank auf repliziertem Speicher

#datei("lab/k8s/postgres.yaml (Ausschnitt)", ```yaml
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
        resources: {requests: {storage: 2Gi}}
```, erklaerung: [Ein StatefulSet mit einer PostgreSQL-Instanz. Ohne `storageClassName` nimmt es die Standardklasse `linstor-replicated`. Das Passwort steht der Einfachheit halber im Klartext, nur fürs Lab.])

#cmd("Mac")[```bash
kubectl apply -f lab/k8s/storageclass.yaml -f lab/k8s/postgres.yaml
kubectl -n demo rollout status sts/pg
kubectl -n demo get pvc,pod -o wide
```][Legt StorageClass und Datenbank an.]

#cmd("k0s-w1")[```bash
linstor resource list -r pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Den Namen der Ressource zeigt `kubectl -n demo get pvc` in der Spalte `VOLUME`.]

#pruefe[
```
│ pvc-0d903f58-... │ k0s-ctrl │ DRBD,STORAGE            │ Unused │ Ok    │ Diskless           │ Yes  │
│ pvc-0d903f58-... │ k0s-w1   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ SyncTarget(36.32%) │ Yes  │
│ pvc-0d903f58-... │ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ InUse  │ Ok    │ UpToDate           │ Yes  │
```
Zwei Zonen, Writecache, Tiebreaker auf der Witness. Der Pod läuft auf `k0s-w2`, dort ist das Volume `InUse`.
]

== Der Umzug

#cmd("Mac")[```bash
kubectl -n demo exec pg-0 -- psql -U postgres \
  -c "create table notizen(id serial primary key, text text, zeit timestamptz default now());" \
  -c "insert into notizen(text) values ('geschrieben auf k0s-w2');"
kubectl cordon k0s-w2
kubectl -n demo delete pod pg-0
kubectl -n demo wait --for=condition=Ready pod/pg-0
kubectl -n demo get pod pg-0 -o wide
kubectl -n demo exec pg-0 -- psql -U postgres -c "select * from notizen;"
kubectl uncordon k0s-w2
```][Eine Zeile schreiben, `k0s-w2` sperren, den Pod löschen. Das StatefulSet startet ihn auf einem anderen Node neu.]

#pruefe[
```
NAME   READY   STATUS    RESTARTS   AGE   IP           NODE     ...
pg-0   1/1     Running   0          31s   10.244.0.6   k0s-w1   ...
 id |          text          |             zeit
----+------------------------+-------------------------------
  1 | geschrieben auf k0s-w2 | 2026-11-12 18:24:41.505541+00
```
Der Pod läuft auf `k0s-w1`, wo das zweite Replikat liegt, und die Zeile ist da. In LINSTOR ist jetzt `k0s-w1` `InUse`.
]

#gelernt(
  [Piraeus kann reiner CSI-Treiber für ein LINSTOR außerhalb von Kubernetes sein.],
  [Der `nodeSelector` des LinstorCluster gilt auch für die CSI-Pods. `null` in der `podTemplate` hebt ihn auf.],
  [Auf k0s braucht der CSI-Node die Pfade unter `/var/lib/k0s/kubelet`.],
  [Fremd verwaltete Nodes brauchen `Aux/topology/linbit.com/hostname`, sonst startet der Operator die CSI-Pods endlos neu.],
  [Die StorageClass überschreibt die Resource-Group. Alle Platzierungsregeln gehören in die StorageClass.],
  [CSI 1.13 braucht LINSTOR 1.35. Mit 1.33 bleibt CSI auf 1.12.],
)
