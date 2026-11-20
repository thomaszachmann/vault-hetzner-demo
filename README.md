# Vault Enterprise Demo on Hetzner Cloud (k3s)

Geo-redundant Vault platform: one k3s cluster per data center with Vault (Helm, Raft, 3 pods),
DR replication fsn1 → nbg1, Transit auto-unseal, namespaces, Keycloak OIDC with MFA,
Kubernetes auth with Vault Agent Injector, central monitoring – built only for the demo.

```bash
mise install          # tools
mise run setup        # check prerequisites, create root CA
mise run deploy       # ~20 min, ~€0.34/h
mise run urls         # GUIs (nip.io, via WireGuard)
mise run destroy      # delete everything
```

Full documentation including the demo script: [docs/vault-demo.md](docs/vault-demo.md) ([PDF](docs/vault-demo.pdf))
