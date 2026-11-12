#import "../lib.typ": *

#kapitel(
  [k0s mit k0sctl installieren],
  ziel: [Ein k0s-Cluster mit einem Controller und drei Workern läuft, und `kubectl` auf dem Mac spricht mit ihm.],
  zeit: [20 Minuten],
  braucht: [Die vorbereiteten VMs aus Kapitel 2, Homebrew auf dem Mac],
)

== Was k0s anders macht

k0s ist eine Kubernetes-Distribution in einer einzigen Datei. Alles, was ein Node braucht, steckt im Binary `k0s`: API-Server, Scheduler, etcd, containerd, kubelet und das Netzwerk-Plugin. Es gibt keine Abhängigkeiten vom Betriebssystem außer dem Kernel.

Zwei Eigenschaften musst du kennen, weil sie sich von k3s und kubeadm unterscheiden:

- *Der Controller ist kein Node.* Auf `k0s-ctrl` läuft kein kubelet. Er taucht in `kubectl get nodes` nicht auf, und auf ihm landen nie Pods. Die Control Plane ist damit vor Workloads geschützt.
- *konnectivity verbindet API-Server und Worker.* Weil der Controller kein Node ist, kann der API-Server die Pods nicht direkt im Pod-Netz erreichen. Für `kubectl logs`, `exec` und `port-forward` baut jeder Worker einen Tunnel zum Controller auf.

#warum[
  Wenn in einem Cluster `kubectl logs` hängt, obwohl die Pods laufen, liegt es oft an konnectivity und nicht am Pod. Das Wissen, dass dieser Tunnel existiert, spart dir dort viel Sucherei.
]

== k0sctl installieren

k0sctl ist das Werkzeug, mit dem du k0s auf mehrere Hosts verteilst. Es läuft auf dem Mac, verbindet sich per SSH zu den VMs und erledigt Download, Konfiguration, Join-Tokens und später auch Updates.

#cmd("Mac")[```bash
brew install k0sproject/tap/k0sctl
k0sctl version
```][Installiert k0sctl aus dem Homebrew-Tap des Projekts.]

#pruefe[
```
version: v0.33.1
commit: c4bfa95
```
]

== Die Cluster-Beschreibung

`k0sctl init` erzeugt ein Gerüst. Das Ergebnis ist lang, weil es jeden Standardwert ausschreibt. Für das Lab reicht eine kurze Datei, in der nur steht, was vom Standard abweicht:

#datei("lab/k0sctl.yaml", ```yaml
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: k0s-lab
spec:
  hosts:
    - role: controller
      ssh: {address: 172.16.0.176, user: ubuntu, keyPath: ~/.ssh/homelab}
    - role: worker
      ssh: {address: 172.16.0.186, user: ubuntu, keyPath: ~/.ssh/homelab}
    - role: worker
      ssh: {address: 172.16.0.36, user: ubuntu, keyPath: ~/.ssh/homelab}
    - role: worker
      ssh: {address: 172.16.0.72, user: ubuntu, keyPath: ~/.ssh/homelab}
  k0s:
    version: v1.36.6+k0s.0
    config:
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      metadata:
        name: k0s-lab
      spec:
        api:
          address: 172.16.0.176
          sans: [172.16.0.176]
        network:
          provider: kuberouter
          podCIDR: 10.244.0.0/16
          serviceCIDR: 10.96.0.0/12
        telemetry:
          enabled: false
```, erklaerung: [
  `spec.hosts` legt fest, wer was wird. `role: controller` bedeutet Control Plane ohne Workloads. Die Rolle `controller+worker` gäbe es auch, sie ist aber nur für Ein-Node-Cluster gedacht.
  `k0s.version` pinnt die Version. Ohne diese Zeile nimmt k0sctl die neueste, und ein späteres `apply` würde den Cluster ungefragt aktualisieren.
  `k0s.config` ist die k0s-Konfiguration selbst. `kuberouter` ist das Standard-Netz von k0s, `telemetry` schaltet das Senden anonymer Statistiken ab.
])

#falle[
  Die Version heißt `v1.36.6+k0s.0`, mit dem Suffix `+k0s.0`. Ohne Suffix findet k0sctl kein Release.
]

== Den Cluster aufbauen

#cmd("Mac")[```bash
k0sctl apply --config lab/k0sctl.yaml
```][k0sctl verbindet sich zu allen vier VMs, lädt k0s herunter, richtet den Controller ein, erzeugt für jeden Worker ein Join-Token und wartet, bis alle Nodes bereit sind.]

#pruefe[
```
level=info msg="==> Running phase: Initialize the k0s cluster"
level=info msg="172.16.0.176:22: installing k0s controller"
level=info msg="172.16.0.176:22: wait for kubernetes to reach ready state"
level=info msg="==> Running phase: Install workers"
level=info msg="172.16.0.176:22: generating a join token for worker 1"
...
level=info msg="172.16.0.186:22: waiting for node to become ready"
level=info msg="==> Finished in 2m42s"
level=info msg="k0s cluster version v1.36.6+k0s.0 is now installed"
```
]

`k0sctl apply` ist idempotent. Du kannst es jederzeit erneut ausführen. Es vergleicht den Ist-Zustand mit der Datei und ändert nur, was abweicht. Genau so fügst du später Nodes hinzu oder aktualisierst k0s.

== kubectl verbinden

#cmd("Mac")[```bash
k0sctl kubeconfig --config lab/k0sctl.yaml > ~/.kube/k0s-lab.yaml
chmod 600 ~/.kube/k0s-lab.yaml
export KUBECONFIG=~/.kube/k0s-lab.yaml
kubectl get nodes -o wide
```][Holt die Admin-Kubeconfig vom Controller und legt sie als eigene Datei ab. Deine bestehende `~/.kube/config` bleibt unberührt. Die Variable `KUBECONFIG` gilt nur in diesem Terminal.]

#pruefe[
```
NAME     STATUS   ROLES    AGE   VERSION       INTERNAL-IP    ... CONTAINER-RUNTIME
k0s-w1   Ready    <none>   50s   v1.36.6+k0s   172.16.0.186   ... containerd://2.3.6
k0s-w2   Ready    <none>   49s   v1.36.6+k0s   172.16.0.36    ... containerd://2.3.6
k0s-w3   Ready    <none>   50s   v1.36.6+k0s   172.16.0.72    ... containerd://2.3.6
```
Drei Nodes, nicht vier. `k0s-ctrl` fehlt, und das ist richtig so.
]

#cmd("Mac")[```bash
kubectl get pods -A
```][Zeigt die Systempods. Direkt nach dem Start hängen einige noch in `ContainerCreating`, nach ein bis zwei Minuten sind alle `Running`.]

Du siehst `coredns`, `kube-proxy`, `kube-router`, `metrics-server` und je Worker einen `konnectivity-agent`. API-Server, Scheduler und etcd fehlen in der Liste, weil sie auf dem Controller als normale Prozesse laufen, nicht als Pods.

== Auf den Nodes nachsehen

#cmd("Mac")[```bash
ssh k0s-ctrl 'sudo k0s status'
ssh k0s-ctrl 'sudo k0s etcd member-list'
ssh k0s-w1 'sudo k0s status'
```][`k0s status` zeigt Rolle und Version des lokalen k0s. `k0s etcd member-list` listet die etcd-Mitglieder.]

#pruefe[
```
Version: v1.36.6+k0s.0
Role: controller
Workloads: false
{"members":{"k0s-ctrl":"https://172.16.0.176:2380"}}

Version: v1.36.6+k0s.0
Role: worker
Workloads: true
Kube-api probing successful: true
```
`Workloads: false` auf dem Controller ist die Bestätigung, dass dort keine Pods laufen. Mit nur einem etcd-Mitglied ist der Controller ein Single Point of Failure. Fällt er aus, laufen die Pods weiter, aber niemand kann den Cluster mehr ändern. Kapitel 18 zeigt, wie drei Controller das lösen.
]

#gelernt(
  [k0s ist ein einziges Binary, k0sctl verteilt es per SSH.],
  [Ein reiner Controller ist kein Node und führt keine Pods aus.],
  [konnectivity tunnelt `logs`, `exec` und `port-forward` vom Controller zu den Workern.],
  [`k0sctl apply` ist idempotent und gleicht den Cluster mit der Datei ab.],
  [`k0s status` und `k0s etcd member-list` sind die ersten Befehle auf einem fremden k0s-Node.],
)
