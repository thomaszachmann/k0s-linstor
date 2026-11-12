#import "../lib.typ": *

#kapitel(
  [Dasselbe mit Ansible],
  ziel: [Die Handarbeit aus den Kapiteln 5 und 6 als zwei Ansible-Rollen: `linstor` für alle Nodes und `linstor-controller-ha` für die Controller-Kandidaten. Du verstehst, was jede Aufgabe tut, weil du sie vorher von Hand gemacht hast.],
  zeit: [30 Minuten],
  braucht: [Ansible auf dem Mac (getestet mit ansible-core 2.20 und `community.general` 12.2), die VMs aus den vorigen Kapiteln],
)

#warum[
  In Produktion installiert eine Automatisierung wie Ansible LINSTOR auf vielen Hosts. Wer dort etwas ändern oder einen Fehler suchen muss, liest Rollen, keine Anleitung. Dieses Kapitel ist die Brücke: Jede Aufgabe der Rollen entspricht einem Befehl, den du in Kapitel 5 oder 6 von Hand ausgeführt hast.
]

== Aufbau

#tabelle(
  (auto, 1fr),
  ([Datei], [Inhalt]),
  [`lab/ansible/inventory.ini`], [Nodes, Gruppen und je Node die beiden IPs und die Zone],
  [`lab/ansible/group_vars/all.yml`], [LINSTOR-Version, VIP, PPA],
  [`lab/ansible/roles/linstor/`], [Pakete, DRBD-Modul, LVM-Filter, Client, Satellite, Metriken],
  [`lab/ansible/roles/linstor-controller-ha/`], [Controller-Paket, Mount-Unit, Promoter],
  [`lab/ansible/site.yml`], [Wendet beide Rollen auf die passenden Gruppen an],
)

#datei("lab/ansible/inventory.ini", raw(read("../../lab/ansible/inventory.ini"), lang: "ini", block: true), erklaerung: [Zwei Gruppen: `linstor_satellites` sind alle Nodes mit DRBD, `linstor_controllers` die Kandidaten für den Controller. Die Witness hat keine `storage_ip`.])

#datei("lab/ansible/group_vars/all.yml", raw(read("../../lab/ansible/group_vars/all.yml"), lang: "yaml", block: true), erklaerung: [Die Version steht an genau einer Stelle. In größeren Umgebungen steht sie oft in `roles/linstor/defaults/main.yml`, mit einer möglichen Überschreibung je Host.])

== Die Rolle linstor

#datei("lab/ansible/roles/linstor/tasks/main.yml", raw(read("../../lab/ansible/roles/linstor/tasks/main.yml"), lang: "yaml", block: true))

#tabelle(
  (auto, auto),
  ([Aufgabe], [Von Hand in]),
  [PPA, Pakete, Header], [Kapitel 5, „Die Pakete installieren“],
  [Version festhalten], [Kapitel 5, `apt-mark hold`],
  [Modul laden, `modules-load.d`], [Kapitel 5],
  [LVM-Filter], [Kapitel 5, „LVM darf DRBD-Geräte nicht anfassen“],
  [Client-Konfiguration], [Kapitel 6, VIP bzw. Kandidatenliste für die Witness],
  [`prometheus.toml`], [Kapitel 17],
)

#falle[
  Die erste Fassung band das PPA mit `ansible.builtin.apt_repository` ein. Der Trockenlauf zeigte, dass das Modul eine zweite Quelle als `.list`-Datei angelegt hätte, neben der `.sources`-Datei, die `add-apt-repository` im deb822-Format erzeugt. Doppelte Quellen sind harmlos, aber verwirrend. Deshalb ruft die Rolle `add-apt-repository` auf, mit `creates` als Schutz vor Wiederholung.
]

Die Vorlage für den Client unterscheidet zwischen Workern und Witness:

#datei("lab/ansible/roles/linstor/templates/linstor-client.conf.j2", raw(read("../../lab/ansible/roles/linstor/templates/linstor-client.conf.j2"), lang: "jinja", block: true))

== Die Rolle linstor-controller-ha

#datei("lab/ansible/roles/linstor-controller-ha/tasks/main.yml", raw(read("../../lab/ansible/roles/linstor-controller-ha/tasks/main.yml"), lang: "yaml", block: true), erklaerung: [Die Mount-Unit liegt unverändert unter `files/`, der Promoter als Vorlage unter `templates/`, damit VIP und Netzwerkkarte aus den Variablen kommen.])

#falle[
  Die Aufgabe für `linstor-controller` setzt nur `enabled: false`, aber *keinen* `state`. Mit `state: stopped` würde Ansible bei jedem Lauf den aktiven Controller anhalten, und drbd-reactor würde die Kette auf einen anderen Node schwenken (Kapitel 15). Die Rolle darf den Controller nie selbst starten oder stoppen.
]

== Ausprobieren

#cmd("Mac")[```bash
cd lab/ansible
ansible-playbook --syntax-check site.yml
ansible-playbook site.yml --check --diff
```][Erst Syntax, dann ein Trockenlauf, der zeigt, was Ansible ändern würde, ohne es zu tun.]

#pruefe[
```
PLAY RECAP *********************************************************************
k0s-ctrl  : ok=12   changed=0    unreachable=0    failed=0    skipped=0
k0s-w1    : ok=18   changed=0    unreachable=0    failed=0    skipped=0
k0s-w2    : ok=18   changed=0    unreachable=0    failed=0    skipped=0
k0s-w3    : ok=18   changed=0    unreachable=0    failed=0    skipped=0
```
]

#cmd("Mac")[```bash
ansible-playbook site.yml
ansible-playbook site.yml
```][Zwei echte Läufe hintereinander.]

#pruefe[
Beide Läufe enden mit `changed=0` auf allen Nodes. Die Rollen beschreiben genau den Zustand, den du in den Kapiteln 5, 6 und 17 von Hand hergestellt hast, und sie verändern nichts, wenn nichts zu tun ist.
]

#hinweis("Was dieser Test zeigt und was nicht", warn, warn-hell)[
  Getestet ist, dass die Rollen zur Handinstallation passen und idempotent sind. Nicht getestet ist ein Lauf gegen einen leeren Node. Dabei würden die Pakete installiert und das Modul gebaut. Die Rollen enthalten außerdem nicht, was einmalig am Controller passiert: Nodes registrieren, Schnittstellen, Pfade, Zonen, Pools, `Aux/topology/linbit.com/hostname`, `linstor_db` anlegen und die Datenbank umziehen. Das sind die Befehle aus den Kapiteln 5 bis 8. In einer bestehenden Umgebung ist zu prüfen, wo diese Schritte automatisiert sind.
]

== Ein Update mit Ansible

Für das LINSTOR-Update aus Kapitel 15 änderst du `linstor_version` in `group_vars/all.yml`. Die Reihenfolge bleibt dieselbe: Mit `--limit` aktualisierst du erst die Nodes ohne aktiven Controller, dann die Witness, und den aktiven Node erst nach `drbd-reactorctl evict`.

#cmd("Mac")[```bash
ansible-playbook site.yml --limit k0s-w1,k0s-w3
ansible-playbook site.yml --limit k0s-ctrl
ssh k0s-w2 'sudo drbd-reactorctl evict linstor_db'
ansible-playbook site.yml --limit k0s-w2
```][Beispiel, wenn der Controller auf `k0s-w2` läuft. Nicht im Lab ausgeführt, das Update lief in Kapitel 15 von Hand.]

#falle[
  Die Rolle hält die Pakete mit `dpkg_selections: hold` fest. Für gehaltene Pakete verweigert `apt` eine andere Version, auch wenn sie ausdrücklich angefordert wird. Deshalb steht in den Paket-Aufgaben `allow_change_held_packages: true`. Ein `apt upgrade` von Hand bleibt blockiert, die Rolle darf die Version ändern. So soll es sein: Updates nur über die Variable. Ob ein Versionswechsel über die Rolle wirklich durchläuft, wurde im Lab nicht getestet.
]

#gelernt(
  [Jede Aufgabe der Rollen entspricht einem Schritt aus der Handinstallation.],
  [`--check --diff` zeigt vor dem Lauf, was sich ändern würde.],
  [Zwei Läufe mit `changed=0` beweisen Idempotenz.],
  [Die Rolle darf den Controller-Dienst nie starten oder stoppen, nur deaktivieren.],
  [Registrierung, Pools und die Controller-Datenbank sind einmalige Schritte außerhalb der Rollen.],
)
