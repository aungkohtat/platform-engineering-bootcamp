# platform-engineering-bootcamp

Building an internal developer platform from scratch on Kubernetes, one component
at a time, during a Platform Engineering Bootcamp (Oct 2026 – May 2027).

Everything here is my own work. Course slides and instructor material are not published.

## Platform

| # | Module | Component | Status |
|---|--------|-----------|--------|
| 00 | [Kubernetes](modules/00-kubernetes/) | Cluster foundation | ⬜ |
| 01 | [Service mesh](modules/01-cilium/) | Cilium | ⬜ |
| 02 | [GitOps](modules/02-fluxcd/) | FluxCD | ⬜ |
| 03 | [SCM](modules/03-gitlab/) | GitLab | ⬜ |
| 04 | [IAM](modules/04-keycloak/) | Keycloak | ⬜ |
| 05 | [Policy](modules/05-kyverno/) | Kyverno | ⬜ |
| 06 | [Secrets](modules/06-openbao/) | OpenBao | ⬜ |
| 07 | [Runtime security](modules/07-falco/) | Falco | ⬜ |
| 08 | [Observability](modules/08-otel-lgtm/) | OpenTelemetry + Loki, Grafana, Tempo, Mimir | ⬜ |
| 09 | [Developer portal](modules/09-backstage/) | Backstage | ⬜ |

⬜ not started · 🟨 in progress · ✅ done

Module order follows the component list, not necessarily the session order.

## Working rules

- **Own cluster.** Use a dedicated cluster name (e.g. `kind-bootcamp`) and confirm
  `kubectl config current-context` before every apply. Never point this repo at a work cluster.
- **Notes after doing.** Each module README is filled in after the lab, from the template in `templates/`.
- **No secrets in git.** `pre-commit` runs gitleaks; install with `pre-commit install`.
  OpenBao and Keycloak dev credentials stay in local env files, which are gitignored.
- The GitOps layout (`clusters/`, `infrastructure/`, `apps/`) is added when the FluxCD module starts.
