# Vault Enterprise Demo auf Hetzner Cloud (k3s)

Geo-redundante Vault-Plattform: je Rechenzentrum ein k3s-Cluster mit Vault (Helm, Raft, 3 Pods),
DR-Replication fsn1 → nbg1, Transit-Auto-Unseal, Namespaces, Keycloak-OIDC mit MFA,
Kubernetes Auth mit Vault Agent Injector, zentrales Monitoring – wird nur für die Vorführung aufgebaut.

```bash
mise install          # Tools
mise run setup        # Voraussetzungen prüfen, Root-CA anlegen
mise run deploy       # ~20 min, ~0,34 €/h
mise run urls         # GUIs (nip.io, über WireGuard)
mise run destroy      # alles löschen
```

Vollständige Dokumentation inkl. Drehbuch: [docs/vault-demo.md](docs/vault-demo.md) ([PDF](docs/vault-demo.pdf))
