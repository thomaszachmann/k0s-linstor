# k0s and LINSTOR

Hands-on handbook: building and running Kubernetes with k0s and replicated block storage with LINSTOR and DRBD, command by command. Tested on four Ubuntu VMs.

**Free course (English and German):** https://itdrills.com/books/k0s-linstor · German edition: https://it-trainingslager.de/buecher/k0s-linstor

**PDF:** [`k0s-und-linstor.pdf`](k0s-und-linstor.pdf) (147 pages, German)

## What it covers

- k0s with k0sctl: one controller, three workers
- LINSTOR and DRBD as packages on the hosts, outside Kubernetes
- highly available LINSTOR controller with drbd-reactor and a virtual IP
- two zones, one witness, a dedicated storage network, write cache on fast storage
- Piraeus Operator only as the CSI driver against the external controller
- Operations: node failure, quorum and split brain, full volumes, backup with Velero, disk replacement, updates
- Ansible roles
- Monitoring with Prometheus, Grafana, Loki and Alertmanager: dashboards, logs and tested alerting rules, worked through on a real DRBD failure

## Repository layout

| Path | Contents |
|---|---|
| `buch/` | source of the book (Typst) |
| `lab/k0sctl.yaml` | cluster description for k0sctl |
| `lab/netplan/` | storage network of the workers |
| `lab/linstor/` | mount unit and drbd-reactor configuration for the controller |
| `lab/piraeus/` | Helm values for Piraeus as a pure CSI driver |
| `lab/k8s/` | StorageClass, sample database, test manifests |
| `lab/backup/` | SeaweedFS as S3 target, Velero values |
| `lab/ansible/` | roles `linstor` and `linstor-controller-ha` |
| `lab/monitoring/` | drbd-reactor metrics, Helm values for kube-prometheus-stack, Loki and Alloy, Mailpit, Grafana dashboards, alerting rules with tests |
| `lab/protokolle/` | recordings of the runs the book was written from |

S3 credentials (`lab/backup/s3.json`, `lab/backup/velero-credentials`) are not in the repository. Chapter 13 shows how to create them.

## Building the PDF yourself

```bash
typst compile --root . buch/main.typ k0s-und-linstor.pdf
```

## Versions

k0s 1.36.6 → 1.37.2, LINSTOR 1.33.3 → 1.35.3, DRBD 9.3.4, drbd-reactor 1.12.0, Piraeus Operator 2.12.0, linstor-csi 1.12.0 → 1.13.1, Velero 1.18.2, kube-prometheus-stack 93.2.2 (Prometheus 3.16, Grafana 13.3), Loki 3.6, Alloy 1.21.

## License

The book is licensed under [CC BY-ND 4.0](https://creativecommons.org/licenses/by-nd/4.0/deed.de). You may freely share the unmodified PDF.

Thomas Zachmann
