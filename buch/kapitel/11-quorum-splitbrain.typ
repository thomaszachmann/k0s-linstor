#import "../lib.typ": *

#kapitel(
  [Betrieb: Netzausfälle, Quorum und Split-Brain],
  ziel: [Du weißt aus eigener Anschauung, was DRBD tut, wenn Verbindungen reißen: wann weitergeschrieben wird, wann alles anhält, wann eine Seite zwangsweise zurücktritt. Und du löst ein echtes Split-Brain auf, ohne die falschen Daten zu behalten.],
  zeit: [60 Minuten],
  braucht: [Den Cluster aus Kapitel 8. Alle Versuche laufen an eigenen Test-Ressourcen.],
)

== Der Versuchsaufbau

Für die Versuche gibt es eine eigene Ressource aus der Vorlage `rg-k8s`. Auf dem Primary läuft ein Schreiber, der jede Sekunde einen Zeitstempel anhängt und sofort `sync` aufruft. An Lücken in dieser Datei siehst du später genau, wann nicht geschrieben werden konnte.

#cmd("k0s-w1")[```bash
linstor resource-group spawn-resources rg-k8s qtest 300M
linstor resource list -r qtest
```][Zwei Replikate, Tiebreaker auf der Witness.]

#pruefe[
```
│ qtest        │ k0s-ctrl │ DRBD,STORAGE            │ Unused │ Ok    │ Diskless │ Yes  │
│ qtest        │ k0s-w2   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
│ qtest        │ k0s-w3   │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
```
]

#cmd("k0s-w3")[```bash
sudo mkfs.ext4 /dev/drbd1002
sudo mkdir -p /mnt/qtest
sudo mount /dev/drbd1002 /mnt/qtest
sudo systemd-run --unit=schreiber bash -c \
  'while true; do date +%T.%N | cut -c1-12 >> /mnt/qtest/log; sync /mnt/qtest/log; sleep 1; done'
```][Die Gerätenummer zeigt `linstor volume list -r qtest`. Beim Mounten wird `k0s-w3` automatisch Primary. `systemd-run` startet den Schreiber als eigenen Dienst, der weiterläuft, wenn deine SSH-Sitzung endet.]

Netzausfälle stellst du nach, indem du `ens19` abschaltest. SSH läuft weiter über `eth0`. Damit das Netz auch dann zurückkommt, wenn etwas hängt, plant ein zweiter Dienst die Rückkehr gleich mit ein:

#cmd("k0s-w2")[```bash
sudo systemd-run --unit=netzweg bash -c \
  'ip link set ens19 down; sleep 60; ip link set ens19 up; netplan apply'
```][60 Sekunden ohne Storage-Netz.]

== Versuch A: Ein Secondary verliert das Netz

Wie oben, auf `k0s-w2`. Nach 15 Sekunden:

#cmd("k0s-w3")[```bash
sudo drbdadm status qtest
```][Die Sicht des Primary.]

#pruefe[
```
qtest role:Primary
  disk:UpToDate open:yes
  k0s-ctrl role:Secondary
    peer-disk:Diskless peer-client:yes
  k0s-w2 connection:Connecting
```
Auf `k0s-w2` steht `disk:Outdated`. w2 weiß, dass es den Anschluss verloren hat, und wird mit diesem Stand nie Primary.
]

Der Primary hat mit sich selbst und der Witness zwei von drei Stimmen, also Quorum. Er schreibt weiter. Nach der Rückkehr des Netzes synchronisiert DRBD die verpassten Blöcke von selbst, ohne dass du etwas tun musst.

Die Lücken in der Datei des Schreibers zeigen aber etwas, das man leicht übersieht:

#cmd("Mac")[```bash
ssh k0s-w3 'cat /mnt/qtest/log' | awk 'NR>1{split(p,a,":");split($0,b,":");
  d=(b[2]*60+b[3])-(a[2]*60+a[3]); if(d>2.5) print "Lücke", p, "->", $0} {p=$0}'
```][Sucht Abstände über 2,5 Sekunden.]

#pruefe[
```
Lücke 19:08:11.460 -> 19:08:22.181
```
]

#warum[
  *Fällt ein Partner weg, frieren die Schreibzugriffe für etwa 10 Sekunden ein.* DRBD bestätigt einen Schreibvorgang erst, wenn der Partner ihn hat. Antwortet der Partner nicht mehr, wartet DRBD, bis das Timeout der Verbindung abläuft, und schreibt erst dann allein weiter. Für eine Datenbank sind das 10 Sekunden ohne Commit. Wer über „kurze Hänger“ bei Netzproblemen klagt, sieht genau das.
]

== Versuch B: Der Primary verliert das Storage-Netz

Jetzt fällt `ens19` auf `k0s-w3` aus, dem Primary. Die Witness erreicht w3 weiter über das Management-Netz. Damit sieht jede Seite außer sich selbst noch die Witness, beide hätten rechnerisch zwei von drei Stimmen.

#pruefe[
```
## w3 (Primary)
qtest role:Primary
  disk:UpToDate open:yes
  k0s-w2 connection:Connecting
## w2
qtest role:Secondary
  disk:Outdated open:no
## Witness
qtest role:Secondary
  disk:Diskless client:yes open:no
  k0s-w2 role:Secondary
    peer-disk:Outdated
  k0s-w3 role:Primary
    peer-disk:UpToDate
```
]

Kein Split-Brain. Der Primary bleibt Primary, w2 setzt sich auf `Outdated`. Die Witness ist mit beiden verbunden und weiß, wer Primary ist. Eine Seite, die nicht Primary ist, kann über sie keine Mehrheit gegen den Primary bilden. Auch hier: eine Lücke von etwa 10 Sekunden, danach Resync von selbst.

#warum[
  Das ist der wahrscheinlichste Fall in dieser Architektur: Das Storage-VLAN hat ein Problem, das Management-Netz nicht. Die Witness im Management-Netz verhindert, dass daraus ein Split-Brain wird.
]

== Versuch C: Der Primary verliert alles

Jetzt ist `k0s-w3` komplett isoliert: kein Storage-Netz und auch keine Verbindung zur Witness. Die Witness-Verbindung kappt eine Firewall-Regel auf den DRBD-Ports:

#cmd("k0s-w3")[```bash
sudo systemd-run --unit=isoliert bash -c '
  iptables -I OUTPUT -d 172.16.0.176 -p tcp --dport 7000:7999 -j DROP
  iptables -I INPUT  -s 172.16.0.176 -p tcp --sport 7000:7999 -j DROP
  ip link set ens19 down; sleep 60; ip link set ens19 up; netplan apply
  iptables -D OUTPUT -d 172.16.0.176 -p tcp --dport 7000:7999 -j DROP
  iptables -D INPUT  -s 172.16.0.176 -p tcp --sport 7000:7999 -j DROP'
sleep 25
sudo drbdsetup status qtest --verbose | head -5
```][60 Sekunden allein.]

#pruefe[
```
qtest node-id:1 role:Primary suspended:quorum force-io-failures:no
  volume:0 minor:1002 disk:UpToDate
      backing_dev:/dev/mapper/linstor_writecache_qtest_00000 quorum:no open:yes
      blocked:upper
```
]

`quorum:no`, `suspended:quorum`, `blocked:upper`: DRBD hat alle Schreibvorgänge angehalten. Das ist die Einstellung `on-no-quorum=suspend-io` aus der Vorlage. Selbst `tail` auf das Dateisystem hängt jetzt. Nach der Rückkehr des Netzes läuft alles von selbst weiter:

#pruefe[
```
Lücke 19:11:34.582 -> 19:12:45.308
```
71 Sekunden Stillstand, kein Datenverlust, keine Fehlermeldung in der Anwendung.
]

== Versuch D: Die andere Seite übernimmt

Was, wenn während der Isolation jemand die andere Seite benutzt? Genau das tut Kubernetes, wenn es den Pod auf einen anderen Node verschiebt. `k0s-w2` hat mit der Witness zwei von drei Stimmen und darf Primary werden.

#cmd("k0s-w2")[```bash
sudo mount /dev/drbd1002 /mnt/qtest
echo "w2 hat übernommen $(date +%T)" | sudo tee -a /mnt/qtest/log
sudo umount /mnt/qtest
```][Während `k0s-w3` isoliert ist und seine Schreibvorgänge angehalten hat.]

Kommt `k0s-w3` zurück, hat es einen veralteten Stand und hängende Schreibvorgänge.

#cmd("k0s-w3")[```bash
sudo drbdsetup status qtest --verbose | head -4
tail -2 /mnt/qtest/log
```][Der zurückgekehrte alte Primary.]

#pruefe[
```
qtest node-id:1 role:Secondary suspended:no force-io-failures:yes
  volume:0 minor:1002 disk:UpToDate
      quorum:yes open:yes
tail: cannot open '/mnt/qtest/log' for reading: Input/output error
```
]

`on-suspended-primary-outdated=force-secondary` hat gegriffen: DRBD hat den alten Primary zum Secondary gemacht, seinen Stand mit den Daten von w2 überschrieben und lässt alle Zugriffe des alten Dateisystems mit Fehlern scheitern (`force-io-failures:yes`). Die Anwendung auf w3 bekommt I/O-Fehler statt veralteter Daten.

#cmd("k0s-w3")[```bash
sudo systemctl stop schreiber
sudo umount /mnt/qtest
```][Aufräumen auf dem alten Primary. Erst danach ist das Gerät wieder normal nutzbar.]

#pruefe[
Auf `k0s-w2` gemountet:
```
19:13:23.181
19:13:24.214
w2 hat übernommen 19:13:45
```
Alles bis zur Isolation, dann der Eintrag von w2. Was w3 während der Isolation schreiben wollte, ist nie angekommen. Es gibt kein Split-Brain.
]

#warum[
  Das ist der Grund für die drei Einstellungen der Vorlage: `quorum=majority` verhindert, dass die Minderheit schreibt. `suspend-io` lässt die Minderheit warten, statt Fehler zu werfen. `force-secondary` räumt auf, wenn die Mehrheit inzwischen weitergemacht hat. Zusammen machen sie ein Split-Brain unmöglich, solange es eine dritte Stimme gibt.
]

== Versuch E: Ein echtes Split-Brain

Ohne Quorum gibt es diesen Schutz nicht. Um zu sehen, wie ein Split-Brain aussieht und wie du es auflöst, bekommt eine Test-Ressource bewusst kein Quorum:

#cmd("k0s-w1")[```bash
linstor resource-group spawn-resources rg-k8s sbtest 200M
linstor resource-definition drbd-options --quorum off sbtest
linstor resource list -r sbtest
```][Mit `quorum off` entfernt LINSTOR den Tiebreaker, er wäre nutzlos.]

#pruefe[
```
│ sbtest       │ k0s-w2 │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
│ sbtest       │ k0s-w3 │ DRBD,WRITECACHE,STORAGE │ Unused │ Ok    │ UpToDate │ Yes  │
```
]

Der Ablauf: auf w2 ein Dateisystem mit dem Inhalt `basis` anlegen, das Storage-Netz von w3 für 60 Sekunden trennen, während der Trennung auf *beiden* Seiten mounten und je eine Zeile schreiben, dann warten.

#cmd("k0s-w2")[```bash
sudo mount /dev/drbd1003 /mnt/sb
echo 'seite w2' | sudo tee -a /mnt/sb/datei
sudo umount /mnt/sb
```][Auf `k0s-w3` dasselbe mit `seite w3`. Ohne Quorum wird jede Seite beim Mounten Primary.]

Nach der Rückkehr des Netzes:

#cmd("k0s-w2")[```bash
sudo drbdadm status sbtest
sudo journalctl -k --since "-2min" | grep -i split
```][Was DRBD beim Wiederverbinden festgestellt hat.]

#pruefe[
```
sbtest role:Secondary
  disk:UpToDate open:no
  k0s-w3 connection:StandAlone
... drbd sbtest/0 drbd1003 k0s-w3: Split-Brain detected but unresolved, dropping connection!
... drbd sbtest k0s-w3: conn( Disconnecting -> StandAlone ) [disconnected]
```
In LINSTOR: `StandAlone(k0s-w3)` bei w2 und `Connecting(k0s-w2)` bei w3.
]

Beide Seiten sind `UpToDate`, und beide haben recht, jede für sich. DRBD kann nicht entscheiden, welche Änderungen zählen, und trennt die Verbindung dauerhaft: `StandAlone` heißt, es wird nicht mehr versucht.

== Das Split-Brain auflösen

#hinweis("Erst entscheiden, dann tippen", warn, warn-hell)[
  Beim Auflösen verwirft eine Seite *alle* Änderungen seit der Trennung, unwiderruflich. Prüfe vorher auf beiden Seiten, was dort steht. Im Zweifel sicherst du die Daten der Verliererseite, bevor du sie verwirfst.
]

#cmd("k0s-w2")[```bash
sudo mount -o ro /dev/drbd1003 /mnt/sb && cat /mnt/sb/datei; sudo umount /mnt/sb
```][Auf beiden Nodes nur lesend mounten und nachsehen.]

#pruefe[
```
w2:  basis          w3:  basis
     seite w2            seite w3
```
]

Hier gewinnt `k0s-w2`. Auf der *Verliererseite* `k0s-w3`:

#cmd("k0s-w3")[```bash
sudo drbdadm disconnect sbtest
sudo drbdadm secondary sbtest
sudo drbdadm connect --discard-my-data sbtest
```][`--discard-my-data` sagt: Meine Änderungen seit der Trennung sind wertlos, übernimm alles von der Gegenseite.]

Auf der *Gewinnerseite* `k0s-w2`, die im Zustand `StandAlone` nicht von selbst wieder verbindet:

#cmd("k0s-w2")[```bash
sudo drbdadm connect sbtest
sudo drbdadm status sbtest
```][Verbindet wieder.]

#pruefe[
```
sbtest role:Secondary
  disk:UpToDate open:no
  k0s-w3 role:Secondary
    peer-disk:UpToDate
```
Im Kernel-Log von w3: `repl( SyncTarget -> Established ) [resync-finished]`. Auf w3 steht jetzt `basis` und `seite w2`. `seite w3` ist weg, wie beabsichtigt.
]

#falle[
  Den Befehl auf der falschen Seite auszuführen, ist der klassische Fehler. `--discard-my-data` gehört *immer* auf den Node, dessen Daten weg sollen. Lies den Befehl vor dem Absenden noch einmal mit dem Hostnamen im Prompt.
]

#cmd("k0s-w1")[```bash
linstor resource-definition delete qtest
linstor resource-definition delete sbtest
```][Räumt die Test-Ressourcen ab.]

== Zusammenfassung der Versuche

#tabelle(
  (auto, 1fr, auto),
  ([Fall], [Verhalten], [Schreibpause]),
  [Secondary verliert Storage-Netz], [Primary schreibt weiter, Secondary `Outdated`, Resync automatisch], [ca. 10 s],
  [Primary verliert Storage-Netz, Witness erreichbar], [Wie oben, kein Split-Brain], [ca. 10 s],
  [Primary komplett isoliert], [`suspended:quorum`, Anwendung hängt bis zur Rückkehr], [so lange wie der Ausfall],
  [Gegenseite übernimmt während der Isolation], [Alter Primary wird `Secondary`, I/O-Fehler, Daten der Mehrheit gelten], [–],
  [Ressource ohne Quorum getrennt beschrieben], [Split-Brain, `StandAlone`, manuelle Auflösung], [keine, dafür Datenverlust auf einer Seite],
)

#gelernt(
  [Mit Quorum und einer dritten Stimme entsteht kein Split-Brain.],
  [Fällt ein Partner aus, frieren Schreibzugriffe etwa 10 Sekunden ein.],
  [Ohne Quorum hält der Primary mit `suspend-io` alles an und macht danach weiter.],
  [`force-secondary` räumt einen veralteten Primary ab, die Anwendung dort bekommt I/O-Fehler.],
  [Ein Split-Brain zeigt sich als `StandAlone`. Aufgelöst wird es mit `connect --discard-my-data` auf der Verliererseite und `connect` auf der Gewinnerseite.],
)
