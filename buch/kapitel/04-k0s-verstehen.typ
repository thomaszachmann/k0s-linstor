#import "../lib.typ": *

#kapitel(
  [k0s verstehen und verwalten],
  ziel: [Du weißt, welche Prozesse auf Controller und Workern laufen, wo k0s seine Dateien ablegt und wie du die Konfiguration sicher änderst.],
  zeit: [30 Minuten],
  braucht: [Den Cluster aus Kapitel 3],
)

== Was auf welchem Node läuft

k0s startet auf jedem Node genau einen systemd-Dienst. Alles andere sind Kindprozesse dieses Dienstes.

#cmd("Mac")[```bash
ssh k0s-ctrl 'systemctl list-units "k0s*" --no-legend'
ssh k0s-ctrl 'ps -eo comm --no-headers | sort -u | grep -E "kube|etcd|konn"'
```][Zeigt den Dienst auf dem Controller und die Prozesse, die er gestartet hat.]

#pruefe[
```
  k0scontroller.service loaded active running k0s - Zero Friction Kubernetes
etcd
konnectivity-se
kube-apiserver
kube-controller
kube-scheduler
```
]

Auf einem Worker heißt der Dienst `k0sworker.service`, und darunter laufen `containerd` und `kubelet`:

#cmd("Mac")[```bash
ssh k0s-w1 'systemctl list-units "k0s*" --no-legend'
ssh k0s-w1 'ps -eo comm --no-headers | sort -u | grep -E "kubelet|containerd$"'
```][Die Prozesse auf dem Worker.]

#tabelle(
  (auto, auto, 1fr),
  ([Node], [Dienst], [Was darunter läuft]),
  [Controller], [`k0scontroller`], [etcd, kube-apiserver, kube-scheduler, kube-controller-manager, konnectivity-server],
  [Worker], [`k0sworker`], [containerd, kubelet; als Pods: kube-proxy, kube-router, konnectivity-agent, coredns],
)

#warum[
  Wenn ein Node Probleme macht, ist die erste Frage: läuft der Dienst? `systemctl status k0sworker` und `journalctl -u k0sworker` sind dort dein Einstieg, nicht `kubectl`. Ein Worker, dessen Dienst steht, meldet sich in Kubernetes nur noch als `NotReady`, ohne zu sagen, warum.
]

== Wo k0s seine Dateien ablegt

#tabelle(
  (auto, 1fr),
  ([Pfad], [Inhalt]),
  [`/etc/k0s/k0s.yaml`], [Die Cluster-Konfiguration auf dem Controller. k0sctl schreibt sie aus dem Abschnitt `spec.k0s.config`.],
  [`/var/lib/k0s/pki`], [Alle Zertifikate des Clusters.],
  [`/var/lib/k0s/etcd`], [Die etcd-Daten. Wer das verliert, verliert den Cluster-Zustand.],
  [`/var/lib/k0s/kubelet`], [Das Arbeitsverzeichnis des kubelets auf den Workern. *Nicht* `/var/lib/kubelet` wie bei fast allen anderen Distributionen.],
  [`/var/lib/k0s/containerd`], [Images und Container-Dateisysteme.],
  [`/etc/k0s/containerd.d/`], [Ergänzungen zur containerd-Konfiguration, zum Beispiel für eine eigene Registry.],
)

#falle[
  Der abweichende kubelet-Pfad `/var/lib/k0s/kubelet` ist der häufigste Grund, warum CSI-Treiber auf k0s nicht funktionieren. Fast alle Helm-Charts gehen von `/var/lib/kubelet` aus. In Kapitel 8 läufst du genau in diese Falle und löst sie.
]

== Werkzeuge auf den Nodes

Das Binary `k0s` bringt seine eigenen Werkzeuge mit. Du musst auf den Nodes nichts zusätzlich installieren.

#cmd("Mac")[```bash
ssh k0s-ctrl 'sudo k0s kubectl get nodes'
ssh k0s-w1 'sudo k0s ctr -n k8s.io containers ls | head -4'
ssh k0s-w1 'sudo k0s sysinfo'
```][`k0s kubectl` ist ein vollwertiges kubectl mit Admin-Rechten, direkt auf dem Controller. `k0s ctr` spricht mit dem containerd des Workers. `k0s sysinfo` prüft, ob der Host alle Voraussetzungen erfüllt.]

#pruefe[
```
Total memory: 3.8 GiB (pass)
File system of /var/lib/k0s: ext4 (pass)
Disk space available for /var/lib/k0s: 22.5 GiB (pass)
...
  Control Groups: version 2 (pass)
```
`k0s sysinfo` ist der erste Befehl auf einem Node, der nicht starten will. Jede Zeile ohne `(pass)` ist ein Kandidat.
]

#cmd("Mac")[```bash
ssh k0s-ctrl 'sudo journalctl -u k0scontroller --since "-10min" --no-pager | tail'
ssh k0s-w1 'sudo journalctl -u k0sworker --since "-10min" --no-pager | tail'
```][Die Logs aller Komponenten landen im Journal des einen Dienstes. Mit `grep component=` filterst du nach einzelnen Komponenten.]

== konnectivity prüfen

Weil der Controller kein Node ist, laufen `kubectl logs`, `exec` und `port-forward` durch die konnectivity-Tunnel der Worker.

#cmd("Mac")[```bash
kubectl -n kube-system get pods -l k8s-app=konnectivity-agent -o wide
kubectl -n demo logs pg-0 --tail=2
```][Je Worker ein Agent. Funktioniert `logs`, funktioniert der Tunnel.]

#falle[
  Hängen `kubectl logs` und `exec`, während `kubectl get pods` sofort antwortet, ist fast immer konnectivity schuld: Agent nicht bereit, Port 8132 auf dem Controller blockiert oder ein Controller-Neustart, nach dem sich die Agents noch nicht neu verbunden haben. Prüfe die Agent-Pods und das Journal des Controllers mit `grep konnectivity`.
]

== Konfiguration ändern

Jede Änderung am Cluster machst du in `lab/k0sctl.yaml` und rollst sie mit `k0sctl apply` aus. Ein Beispiel, das du später brauchst: Die Worker bekommen ihre Zone als Kubernetes-Label, passend zu den Zonen in LINSTOR.

#datei("lab/k0sctl.yaml (Ausschnitt)", ```yaml
    - role: worker
      ssh: {address: 172.16.0.186, user: ubuntu, keyPath: ~/.ssh/homelab}
      installFlags: [--labels=topology.kubernetes.io/zone=a]
    - role: worker
      ssh: {address: 172.16.0.36, user: ubuntu, keyPath: ~/.ssh/homelab}
      installFlags: [--labels=topology.kubernetes.io/zone=b]
    - role: worker
      ssh: {address: 172.16.0.72, user: ubuntu, keyPath: ~/.ssh/homelab}
      installFlags: [--labels=topology.kubernetes.io/zone=a]
```, erklaerung: [`installFlags` sind Parameter für `k0s install worker`. Labels, die so gesetzt werden, stehen in der Dienst-Definition und überleben jeden Neustart. Ein `kubectl label` dagegen ginge verloren, wenn der Node neu registriert wird.])

#cmd("Mac")[```bash
k0sctl apply --config lab/k0sctl.yaml
kubectl get nodes -L topology.kubernetes.io/zone
```][k0sctl erkennt die geänderten Flags und installiert den Dienst auf den drei Workern neu.]

#pruefe[
```
level=info msg="==> Running phase: Reinstall"
level=info msg="172.16.0.186:22: reinstalling k0s"
level=info msg="172.16.0.36:22: reinstalling k0s"
level=info msg="172.16.0.72:22: reinstalling k0s"
level=info msg="==> Finished in 1m2s"
NAME     STATUS   ROLES    AGE   VERSION       ZONE
k0s-w1   Ready    <none>   73m   v1.36.6+k0s   a
k0s-w2   Ready    <none>   73m   v1.36.6+k0s   b
k0s-w3   Ready    <none>   73m   v1.36.6+k0s   a
```
]

#falle[
  k0sctl hat alle drei Worker *gleichzeitig* neu installiert. Dabei startet der kubelet neu, laufende Pods überleben das in der Regel. Bei einem großen Cluster willst du das nicht auf allen Nodes auf einmal. `k0sctl apply` kennt dafür `--concurrency`, zum Beispiel `--concurrency 1`. Bei acht oder mehr Nodes ist das die sichere Wahl.
]

#gelernt(
  [Ein Dienst pro Node: `k0scontroller` oder `k0sworker`. Alle Logs stehen in dessen Journal.],
  [k0s legt alles unter `/var/lib/k0s` ab, auch das kubelet.],
  [`k0s kubectl`, `k0s ctr` und `k0s sysinfo` sind auf jedem Node vorhanden.],
  [Hängen `logs` und `exec`, prüfe konnectivity.],
  [Änderungen gehören in `k0sctl.yaml`, ausgerollt mit `k0sctl apply`, bei großen Clustern mit `--concurrency`.],
)
