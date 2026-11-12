#import "../lib.typ": *

#kapitel(
  [LINSTOR und DRBD lesen],
  ziel: [Du liest aus den Ausgaben von `linstor` und `drbdadm`, ob ein Volume gesund ist, wer schreibt, wer mitstimmt und über welches Netz die Daten fließen. Das ist das Handwerkszeug für alle Betriebskapitel.],
  zeit: [30 Minuten],
  braucht: [Die PostgreSQL-Datenbank aus Kapitel 8],
)

== Zwei Sichten auf dasselbe Volume

LINSTOR und DRBD sehen ein Volume unterschiedlich:

- *LINSTOR* kennt den Soll-Zustand: welche Ressource auf welchem Node mit welchen Schichten liegen soll. Den Ist-Zustand fragt es bei den Satellites ab.
- *DRBD* kennt nur den Ist-Zustand auf diesem einen Node: Rolle, Platte, Verbindungen.

Wenn die beiden sich widersprechen, gilt DRBD. LINSTOR kann veraltet sein, etwa wenn ein Satellite nicht erreichbar ist.

Für die folgenden Befehle brauchst du den Namen der Ressource:

#cmd("Mac")[```bash
kubectl -n demo get pvc data-pg-0 -o jsonpath='{.spec.volumeName}{"\n"}'
```][Der PV-Name ist der Name der LINSTOR-Ressource.]

#pruefe[
```
pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```
Im Folgenden kurz `pvc-0d90...`.
]

== Die Sicht von LINSTOR

#cmd("k0s-w1")[```bash
linstor volume list -r pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Eine Zeile pro Kopie.]

#pruefe[
```
│ Node     │ StoragePool          │ MinorNr │ DeviceName    │ Allocated │ InUse  │    State │ Repl           │
│ k0s-ctrl │ DfltDisklessStorPool │    1001 │ /dev/drbd1001 │           │ Unused │ Diskless │ Established(2) │
│ k0s-w1   │ pool_data            │    1001 │ /dev/drbd1001 │  2.11 GiB │ InUse  │ UpToDate │ Established(2) │
│ k0s-w2   │ pool_data            │    1001 │ /dev/drbd1001 │  2.11 GiB │ Unused │ UpToDate │ Established(2) │
```
]

#tabelle(
  (auto, 1fr),
  ([Spalte], [Was sie sagt]),
  [`MinorNr`, `DeviceName`], [Das Gerät auf jedem Node, hier überall `/dev/drbd1001`.],
  [`Allocated`], [Belegter Platz. 2 GiB plus DRBD-Metadaten plus Writecache-Anteil.],
  [`InUse`], [Wer das Gerät offen hat. Genau ein Node, solange der Pod läuft.],
  [`State`], [`UpToDate` heißt: aktuelle Daten. `Diskless` heißt: keine eigenen Daten.],
  [`Repl`], [Zustand der Replikation zu den anderen Kopien. `Established(2)` heißt: zu beiden verbunden.],
)

#cmd("k0s-w1")[```bash
linstor resource-definition list-properties pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Eigenschaften, die der CSI-Treiber gesetzt hat.]

#pruefe[
```
│ Aux/csi-provisioning-completed-by    │ linstor-csi/v1.12.0 │
│ Aux/csi.storage.k8s.io/pvc/name      │ data-pg-0           │
│ Aux/csi.storage.k8s.io/pvc/namespace │ demo                │
│ DrbdOptions/Resource/quorum          │ majority            │
│ DrbdOptions/auto-verify-alg          │ crct10dif           │
```
Über `Aux/csi.storage.k8s.io/pvc/name` findest du zu jeder LINSTOR-Ressource das PVC, ohne Kubernetes zu fragen.
]

== Die Sicht von DRBD

#cmd("k0s-w1")[```bash
sudo drbdadm status pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Der wichtigste Befehl im Betrieb. Ohne Ressourcennamen zeigt er alle Ressourcen.]

#pruefe[
```
pvc-0d903f58-5691-4cda-bb3e-a155de0ced03 role:Primary
  disk:UpToDate open:yes
  k0s-ctrl role:Secondary
    peer-disk:Diskless peer-client:yes
  k0s-w2 role:Secondary
    peer-disk:UpToDate
```
]

So liest du das:

#tabelle(
  (auto, 1fr),
  ([Zeile], [Bedeutung]),
  [`role:Primary`], [Dieser Node darf schreiben. Es gibt immer höchstens einen.],
  [`disk:UpToDate open:yes`], [Die lokale Kopie ist aktuell, und jemand hat das Gerät geöffnet, hier das Dateisystem des Pods.],
  [`k0s-ctrl role:Secondary`], [Verbindung zur Witness, die nur liest und mitstimmt.],
  [`peer-disk:Diskless`], [Die Gegenseite hat keine Daten. Bei `k0s-w2` steht `UpToDate`.],
)

Ein gesundes Volume sieht immer so aus. Jede Abweichung ist ein Hinweis:

#tabelle(
  (auto, 1fr),
  ([Du siehst], [Das heißt]),
  [`connection:Connecting`], [Die Gegenseite ist nicht erreichbar. Netz oder Node prüfen.],
  [`connection:StandAlone`], [DRBD versucht nicht mehr, sich zu verbinden. Fast immer nach einem Split-Brain (Kapitel 11).],
  [`disk:Outdated`], [Diese Kopie weiß, dass sie veraltet ist. Sie wird nie Primary.],
  [`disk:Inconsistent`], [Wird gerade synchronisiert und ist unvollständig.],
  [`replication:SyncSource`/`SyncTarget`], [Resync läuft. `done:` zeigt den Fortschritt.],
  [`quorum:no`], [Keine Mehrheit erreichbar. Je nach Einstellung hängen die Schreibvorgänge oder schlagen fehl.],
  [`suspended:quorum`], [Der Primary hat die Ein- und Ausgabe angehalten, weil das Quorum fehlt.],
)

== Mehr Details

#cmd("k0s-w1")[```bash
sudo drbdsetup status --verbose --statistics pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Dieselbe Ressource mit allen Zählern.]

#pruefe[
```
pvc-0d903f58-... node-id:1 role:Primary suspended:no
  volume:0 minor:1001 disk:UpToDate
      backing_dev:/dev/mapper/linstor_writecache_pvc-0d903f58-..._00000
      quorum:yes open:yes
      size:2100760 read:6596 written:2174708 al-writes:11 bm-writes:250 upper-pending:0
      lower-pending:0 al-suspended:no blocked:no
  k0s-ctrl node-id:2 connection:Connected role:Secondary tls:no congested:no
    volume:0 replication:Established peer-disk:Diskless peer-client:yes
        received:0 sent:0 out-of-sync:0 pending:0 unacked:0
  k0s-w2 node-id:0 connection:Connected role:Secondary tls:no congested:no
    volume:0 replication:Established peer-disk:UpToDate resync-suspended:no
        received:58844 sent:2936 out-of-sync:0 pending:0 unacked:0
```
]

Drei Werte sind im Betrieb besonders nützlich:

- `backing_dev` zeigt, worauf DRBD schreibt. Hier das Writecache-Gerät, darunter liegen die beiden LVs.
- `quorum:yes` bestätigt, dass dieser Node eine Mehrheit sieht.
- `out-of-sync` zählt die KiB, die der Gegenseite fehlen. Im Normalbetrieb ist der Wert 0. Steigt er bei einer verbundenen Gegenseite, kommt das Netz nicht hinterher.

#cmd("k0s-w1")[```bash
sudo drbdsetup show pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Die wirksame Konfiguration, wie DRBD sie gerade benutzt.]

#pruefe[
```
resource "pvc-0d903f58-..." {
    options {
        on-no-data-accessible	suspend-io;
        quorum          	majority;
        on-suspended-primary-outdated	force-secondary;
    }
    ...
    connection {
        _peer_node_id 2;
        path {
            _this_host ipv4 172.16.0.186:7001;
            _remote_host ipv4 172.16.0.176:7001;
        }
        net {
            cram-hmac-alg   	"sha1";
            shared-secret   	"<geschwärzt>";
            ...
```
`on-no-quorum` taucht nicht auf, weil `suspend-io` der Standardwert ist. `drbdsetup show` zeigt nur Abweichungen.
]

#falle[
  `drbdsetup show` gibt das gemeinsame Geheimnis jeder Verbindung im Klartext aus. Kopiere die Ausgabe nie ungefiltert in ein Ticket oder einen Chat.
]

== Die Sicht der Witness

#cmd("k0s-ctrl")[```bash
sudo drbdadm status pvc-0d903f58-5691-4cda-bb3e-a155de0ced03
```][Dieselbe Ressource von der Witness aus.]

#pruefe[
```
pvc-0d903f58-... role:Secondary
  disk:Diskless client:yes open:no
  k0s-w1 role:Primary
    peer-disk:UpToDate
  k0s-w2 role:Secondary
    peer-disk:UpToDate
```
Von hier aus siehst du auf einen Blick, wer Primary ist. Das ist praktisch, wenn du nicht weißt, auf welchem Worker der Pod läuft.
]

== Fehlerberichte des Controllers

Wenn LINSTOR eine Aktion nicht ausführen kann, legt es einen Fehlerbericht an:

#cmd("k0s-w1")[```bash
linstor error-reports list
```][Listet alle Berichte. Im Moment ist die Liste leer.]

Mit `linstor error-reports show <Id>` liest du einen Bericht im Detail. Er enthält den Stacktrace und meist den genauen Befehl auf dem Satellite, der gescheitert ist. Bei Problemen mit LINSTOR ist das die zweite Anlaufstelle nach `journalctl -u linstor-satellite` auf dem betroffenen Node.

#gelernt(
  [LINSTOR kennt den Soll-Zustand, DRBD den Ist-Zustand. Im Zweifel gilt DRBD.],
  [`drbdadm status` ist der wichtigste Befehl im Betrieb.],
  [`out-of-sync`, `quorum` und `backing_dev` aus `drbdsetup status --verbose --statistics` zeigen Netz, Mehrheit und Gerätestapel.],
  [`drbdsetup show` zeigt die wirksame Konfiguration samt Geheimnis.],
  [Fehlerberichte und das Satellite-Journal erklären, warum LINSTOR etwas nicht getan hat.],
)
