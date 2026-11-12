#import "lib.typ": *

#cover(
  [k0s und\ LINSTOR],
  [Kubernetes mit repliziertem Block-Speicher aufbauen und betreiben, Befehl für Befehl],
  [Thomas Zachmann],
  [Stand: 12. November 2026],
)

#show: buch

#set page(numbering: "1")
#counter(page).update(1)

#include "kapitel/00-vorwort.typ"
#include "kapitel/01-architektur.typ"
#include "kapitel/02-vorbereitung.typ"
#include "kapitel/03-k0s-installieren.typ"
#include "kapitel/04-k0s-verstehen.typ"
#include "kapitel/05-linstor-pakete.typ"
#include "kapitel/06-controller-ha.typ"
#include "kapitel/07-pools-zonen.typ"
#include "kapitel/08-csi.typ"
#include "kapitel/09-zustaende-lesen.typ"
#include "kapitel/10-node-ausfall.typ"
#include "kapitel/11-quorum-splitbrain.typ"
#include "kapitel/12-kapazitaet.typ"
#include "kapitel/13-backup.typ"
#include "kapitel/14-plattentausch.typ"
#include "kapitel/15-updates.typ"
#include "kapitel/16-ansible.typ"
#include "kapitel/17-ueberwachung.typ"
#include "kapitel/18-produktion.typ"
#include "kapitel/19-anhang.typ"

#rueckseite(
  [k0s und LINSTOR],
  [
    Vier Ubuntu-VMs, ein Laptop und eine Frage: Was passiert mit meinen Daten, wenn ein Node ausfällt, ein Netz reißt oder eine Platte stirbt?

    Dieses Buch baut Kubernetes mit k0s und replizierten Block-Speicher mit LINSTOR und DRBD Befehl für Befehl auf. LINSTOR läuft außerhalb des Clusters auf den Hosts, sein Controller ist hochverfügbar, Kubernetes nutzt ihn über CSI. Danach wird alles absichtlich kaputtgemacht und repariert, mit gemessenen Ausfallzeiten aus dem Lab.
  ],
  (
    ([Aufbau], [k0s mit k0sctl, LINSTOR und DRBD als Host-Pakete]),
    ([Hochverfügbarkeit], [Controller-Failover mit drbd-reactor und VIP]),
    ([Speicher], [Zonen, Witness, Writecache, Piraeus als reiner CSI-Treiber]),
    ([Ausfälle], [Node weg, Netz weg, Quorum, Split-Brain, Plattentausch]),
    ([Betrieb], [Kapazität, Backup mit Velero, Updates in der richtigen Reihenfolge]),
    ([Automatisierung], [Ansible-Rollen und getestete Alarmregeln]),
  ),
  [Hands-on-Handbuch · Stand: 12. November 2026],
  autor: [Thomas Zachmann],
  autor-bild: "bilder/autor.jpg",
  autor-text: [Autor auf Leanpub],
)
