#import "../lib.typ": *

#kapitel(
  [Vom Lab zur Produktion],
  ziel: [Du weißt, was in Produktion anders ist als im Lab, welche Entscheidungen dort anstehen und welche Fragen du einem bestehenden Setup stellen solltest.],
  zeit: [20 Minuten Lesen],
)

#hinweis("Nicht im Lab getestet", warn, warn-hell)[
  Dieses Kapitel beschreibt Architektur und Abwägungen. Was hier steht, wurde nicht auf den Lab-VMs ausgeführt, außer wo ausdrücklich ein Kapitel genannt ist.
]

== Lab und Produktion im Vergleich

#tabelle(
  (auto, 1fr, 1fr),
  ([Thema], [Lab], [typische Produktion]),
  [Hosts], [4 VMs], [8 Hosts in zwei Zonen, Witness an einem dritten Standort],
  [k0s-Controller], [1], [Zu prüfen. Mit einem Controller ist die Control Plane ein Single Point of Failure.],
  [LINSTOR-Controller], [1 aktiv, 3 Kandidaten], [1 aktiv, Kandidaten laut Gruppe `linstor_controllers`],
  [`linstor_db`], [3 Kopien + Witness], [Kopien auf allen Hosts + Witness],
  [Datenplatten], [eine VM-Platte, in zwei Partitionen geteilt], [HDDs für `pool_data`, NVMe für `pool_nvme`],
  [Storage-Netz], [Proxmox-Bridge ohne Port], [eigenes VLAN auf eigenen Bonds],
  [Installation], [von Hand, dann Ansible], [Ansible],
)

== Mehrere k0s-Controller

Mit einem k0s-Controller laufen die Pods bei dessen Ausfall weiter, aber niemand kann den Cluster ändern, und Pods auf ausgefallenen Workern werden nicht ersetzt. Für Produktion nimmt man drei Controller:

- In `k0sctl.yaml` drei Hosts mit `role: controller`. k0s bildet daraus einen etcd-Cluster mit drei Mitgliedern.
- Ein Load-Balancer oder eine virtuelle IP vor der API auf Port 6443, 9443 (Join) und 8132 (konnectivity). k0s bringt dafür einen eigenen Mechanismus mit, *Control Plane Load Balancing* (CPLB) mit Keepalived. Alternativ ein externer Load-Balancer, dessen Adresse in `spec.api.externalAddress` steht.
- `spec.api.sans` um die VIP ergänzen.

Prüfe in einer bestehenden Umgebung: Wie viele Controller laufen? Was steht in `k0s etcd member-list`?

== Das Storage-Netz

- Replikation braucht Bandbreite und vor allem niedrige Latenz. Jeder Schreibvorgang wartet auf die Gegenseite (Kapitel 1).
- Ein Bond aus zwei Ports schützt vor einem Kabel- oder Switch-Ausfall. Die Versuche aus Kapitel 11 zeigen, was ohne Redundanz passiert: Schreibpausen von etwa 10 Sekunden bei jeder Unterbrechung.
- Satellite-Verkehr und Replikation laufen im Lab über dasselbe Netz. In Produktion ist zu klären, ob das auch so ist.
- Die Witness sitzt außerhalb des Storage-Netzes. Das ist gewollt, siehe Kapitel 11, Versuch B: Fällt nur das Storage-Netz aus, entscheidet die Witness über das Management-Netz.

== Writecache: Nutzen und Preis

Der Writecache auf NVMe macht Schreibvorgänge auf HDDs schnell. Dafür nimmst du drei Dinge in Kauf, die dieses Buch im Lab gefunden hat:

+ *Vergrößern scheitert*, wenn der Zuwachs größer ist als der freie Platz in `pool_nvme` (Kapitel 12).
+ *Vergrößern gelingt scheinbar und ist wirkungslos*: Das Writecache-Gerät wächst nicht mit. Der Fehler besteht in LINSTOR 1.33.3 und 1.35.3 (Kapitel 12 und 15). Kontrolle mit `df` im Pod ist Pflicht.
+ *Snapshots* mit klassischem LVM ab LINSTOR 1.35 reservieren die volle Größe (Kapitel 15).

Kläre in einer bestehenden Umgebung, ob Volumes je vergrößert wurden, und prüfe sie mit `dmsetup table` gegen `blockdev --getsz` des Daten-LVs.

== Der Piraeus-Operator am externen Controller

Der Operator verändert globale Eigenschaften des Controllers (Kapitel 8). Am wichtigsten: `DrbdOptions/AutoEvictAllowEviction=false`. Ausgefallene Nodes werden also nie automatisch geräumt. Zusammen mit dem abgeschalteten HA-Controller heißt das: Bei einem dauerhaften Ausfall braucht es einen Menschen, der das Out-of-Service-Taint setzt (Kapitel 10). Das gehört ins Betriebshandbuch, mit Telefonnummer.

== Fragen an ein bestehendes Setup

Wer ein laufendes System übernimmt, kann mit diesen Befehlen in einer Stunde viel lernen:

#tabelle(
  (auto, 1fr),
  ([Frage], [Befehl]),
  [Welche Versionen laufen?], [`linstor controller version`, `cat /proc/drbd`, `k0s version`],
  [Wo läuft der Controller?], [`drbd-reactorctl status linstor_db`],
  [Sind alle Nodes online?], [`linstor node list`],
  [Gibt es kaputte Ressourcen?], [`linstor resource list --faulty`],
  [Gibt es Split-Brains?], [`drbdadm status | grep -B3 StandAlone` auf jedem Node],
  [Wie voll sind die Pools?], [`linstor storage-pool list`],
  [Was setzt der Operator?], [`linstor controller list-properties`],
  [Welche StorageClasses gibt es, was steht drin?], [`kubectl get sc -o yaml`, danach `linstor resource-group list`],
  [Gibt es Fehlerberichte?], [`linstor error-reports list`],
  [Haben alle CSI-Nodes die Topologie-Eigenschaft?], [`linstor node list-properties <node> | grep topology`],
)

#gelernt(
  [Drei k0s-Controller mit VIP oder Load-Balancer beseitigen den letzten Single Point of Failure.],
  [Das Storage-Netz braucht Redundanz. Unterbrechungen kosten Schreibpausen.],
  [Writecache-Volumes brauchen beim Vergrößern Handarbeit und Kontrolle.],
  [Ohne HA-Controller und Auto-Eviction braucht ein dauerhafter Ausfall einen Menschen.],
)
