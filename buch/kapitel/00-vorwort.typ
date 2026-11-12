#import "../lib.typ": *
#set heading(numbering: none)

#heading(level: 1, numbering: none, outlined: false)[Inhalt]

#{
  show outline.entry.where(level: 1): it => {
    v(0.55em, weak: true)
    strong(it)
  }
  outline(title: none, depth: 2, indent: 1.2em)
}

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[Vorwort]

Die offiziellen Anleitungen erklären jedes Werkzeug für sich. Wie k0s, ein LINSTOR außerhalb von Kubernetes, drbd-reactor und der Piraeus-Operator als reiner CSI-Treiber zusammenspielen, und was passiert, wenn dabei etwas ausfällt, steht nirgends an einer Stelle.

Das Buch baut dieses Zusammenspiel auf vier VMs Befehl für Befehl auf und macht es danach absichtlich kaputt: Nodes fallen aus, Netze reißen, Platten laufen voll, Updates gehen schief. Zu jedem Schritt gibt es eine Erklärung, warum er nötig ist, und eine Prüfung, woran du erkennst, dass er gewirkt hat.

== Für wen

Für Administratorinnen und Administratoren, die Kubernetes und Linux kennen und mit replizierendem Block-Speicher arbeiten müssen, sei es im Aufbau oder im Betrieb. Du solltest wissen, was ein PVC und ein StatefulSet ist und wie man mit LVM eine Volume-Group anlegt. DRBD und LINSTOR erklärt das Buch von Grund auf.

== Was geprüft wurde

Jeder Befehl und jede Ausgabe in diesem Buch stammen aus einem Lauf im November 2026 auf vier Ubuntu-24.04-VMs unter Proxmox. Die Protokolle dieser Läufe liegen im Begleit-Repository unter `lab/protokolle/`. Lange Ausgaben sind gekürzt, das ist mit `...` markiert. Hostnamen, IPs und Ressourcennamen sind die des Labs.

Ausdrücklich *nicht* getestet und im Text so markiert sind:

- ein Export der LINSTOR-Datenbank mit `linstor-database export-db` (scheiterte im Lab, Kapitel 15)
- ein Lauf der Ansible-Rollen gegen einen leeren Node und ein Versionswechsel über die Rollen (Kapitel 16)
- Prometheus, Alertmanager und Grafana selbst. Getestet sind Metriken und Alarmregeln (Kapitel 17).
- mehrere k0s-Controller und alles in Kapitel 18

== Versionen

k0s 1.36.6 und 1.37.2, LINSTOR 1.33.3 und 1.35.3, DRBD 9.3.4, drbd-reactor 1.12.0, Piraeus-Operator 2.12.0, linstor-csi 1.12.0 und 1.13.1. Die vollständige Liste steht in Kapitel 1.

== Die Architektur

Das Lab baut ein verbreitetes Produktionsmuster nach: LINSTOR als Host-Pakete mit drbd-reactor, zwei Zonen mit einer Witness, ein eigenes Storage-Netz, Writecache auf NVMe vor HDDs, Piraeus nur als CSI. Kapitel 1 erklärt, warum.

== Begleit-Repository

Alle Dateien, die das Buch anlegt, liegen im Repository unter `lab/`. Wo das Buch eine Datei zeigt, steht ihr Pfad im Kopf des Kastens. Alle Befehle mit dem Etikett *Mac* laufen im Wurzelverzeichnis des Repositorys.

== Wo du einen Befehl ausführst

Jeder Befehl trägt ein Etikett:

#tabelle(
  (auto, 1fr),
  ([Etikett], [Ort]),
  [*Mac*], [Dein Rechner mit `kubectl`, `helm`, `k0sctl`, `velero` und `ansible`. `KUBECONFIG` zeigt auf `~/.kube/k0s-lab.yaml`.],
  [*k0s-w1* usw.], [Eine Shell auf dieser VM, per `ssh k0s-w1`. Die Kurznamen richtet Kapitel 2 ein.],
)
