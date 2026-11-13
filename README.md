# k0s und LINSTOR

Hands-on-Handbuch: Kubernetes mit k0s und repliziertem Block-Speicher mit LINSTOR und DRBD aufbauen und betreiben, Befehl für Befehl. Auf vier Ubuntu-VMs getestet.

**PDF:** [`k0s-und-linstor.pdf`](k0s-und-linstor.pdf) (147 Seiten, Deutsch)

## Worum es geht

- k0s mit k0sctl: ein Controller, drei Worker
- LINSTOR und DRBD als Pakete auf den Hosts, außerhalb von Kubernetes
- hochverfügbarer LINSTOR-Controller mit drbd-reactor und virtueller IP
- zwei Zonen, eine Witness, eigenes Storage-Netz, Writecache auf schnellem Speicher
- Piraeus-Operator nur als CSI-Treiber gegen den externen Controller
- Betrieb: Node-Ausfall, Quorum und Split-Brain, volle Volumes, Backup mit Velero, Plattentausch, Updates
- Ansible-Rollen
- Monitoring mit Prometheus, Grafana, Loki und Alertmanager: Dashboards, Logs und getestete Alarmregeln, an einem echten DRBD-Fehler durchgespielt

## Aufbau des Repositorys

| Pfad | Inhalt |
|---|---|
| `buch/` | Quelltext des Buchs (Typst) |
| `lab/k0sctl.yaml` | Cluster-Beschreibung für k0sctl |
| `lab/netplan/` | Storage-Netz der Worker |
| `lab/linstor/` | Mount-Unit und drbd-reactor-Konfiguration für den Controller |
| `lab/piraeus/` | Helm-Werte für Piraeus als reinen CSI-Treiber |
| `lab/k8s/` | StorageClass, Beispiel-Datenbank, Test-Manifeste |
| `lab/backup/` | SeaweedFS als S3-Ziel, Velero-Werte |
| `lab/ansible/` | Rollen `linstor` und `linstor-controller-ha` |
| `lab/monitoring/` | drbd-reactor-Metriken, Helm-Werte für kube-prometheus-stack, Loki und Alloy, Mailpit, Grafana-Dashboards, Alarmregeln mit Tests |
| `lab/protokolle/` | Mitschnitte der Läufe, aus denen das Buch entstand |

Zugangsdaten für S3 (`lab/backup/s3.json`, `lab/backup/velero-credentials`) sind nicht im Repository. Kapitel 13 zeigt, wie du sie erzeugst.

## PDF selbst bauen

```bash
typst compile --root . buch/main.typ k0s-und-linstor.pdf
```

## Versionen

k0s 1.36.6 → 1.37.2, LINSTOR 1.33.3 → 1.35.3, DRBD 9.3.4, drbd-reactor 1.12.0, Piraeus-Operator 2.12.0, linstor-csi 1.12.0 → 1.13.1, Velero 1.18.2, kube-prometheus-stack 93.2.2 (Prometheus 3.16, Grafana 13.3), Loki 3.6, Alloy 1.21.

## Lizenz

Das Buch steht unter [CC BY-ND 4.0](https://creativecommons.org/licenses/by-nd/4.0/deed.de). Die unveränderte PDF darfst du frei weitergeben.

Thomas Zachmann
