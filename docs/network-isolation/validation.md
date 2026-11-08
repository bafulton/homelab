# Preflight validation results

Collected 2026-11-07 against context `homelab`. Live nodes were Ready, running Talos 1.14.5 / Kubernetes 1.37.2: beelink (amd64 control plane), rpi5 (arm64 home), ocifree (arm64 remote). Live Flannel pods contained only Flannel/install-config containers using `ghcr.io/siderolabs/flannel:0.28.9`; no policy sidecar was observed.

| Check | Result | Evidence / limitation |
|---|---|---|
| Full three-node baseline | **72/72 passed** | `evidence/baseline.json`: all nine source→destination node pairs, two client roles, pod/Service paths, TCP/UDP DNS. DNS checks repeat per destination. |
| Missing-enforcement detection | **Correctly exited nonzero** | `evidence/no-engine.json`: beelink-only fixture. Two ingress and two egress checks expected denial but observed connectivity. All allowed controls passed. This is an expected diagnostic failure, not a successful isolation test. |
| Policy removal / recovery | **8/8 between-phase and 8/8 final rollback probes passed** | Same beelink fixture; namespace cleanup completed. Since policies were unenforced, this does not prove removal of active blocking rules. |
| Harness infrastructure failure behavior | **4 regression tests passed** | Exec/transport errors cannot count as successful denial; pod setup failure triggers deletion of the generated namespace; comparison recognizes TCP defaults without hiding UDP or missing-policy differences. Run `python3 -m unittest discover -s scripts/network-isolation -p 'test_*.py' -v`. |
| Python compile | Passed | Both tools and regression tests compile. |
| Active enforcement, deny convergence, agent crash/restart | **Pending** | Requires version-matched disposable rehearsal and separately reviewed activation. |
| LAN/tailnet egress, unrelated production databases/admin endpoints | **Pending** | Optional explicit target support is present; no such endpoints were probed in this preflight. |
| Production gateway/identity/monitoring/storage/backup functionality under policy | **Pending** | Dependency matrix and policy review identify required checks. |
| Engine disablement and kernel rule cleanup | **Pending — activation blocker** | Runbook separates policy rollback from engine rollback. |

Neither test run enabled cluster enforcement or changed production policies. The only mutations were uniquely named `cat6-probe-*` namespaces and their disposable pods, Services, and test policies. They were removed on completion. Persisted JSON includes namespace names for auditability.

Fresh dependency update and `helm template --include-crds` completed for **all 37 wrapper charts**. Only Argo CD and Longhorn emitted policies, matching the 12 live objects. Three raw spec differences were omitted `protocol` fields in Argo metrics rules; the API defaults those to TCP. After applying that default, no policy spec drift remained. `evidence/audit.json` preserves both the raw difference list and normalized comparison. Helm also emitted the existing `zookeeper.initContainers: Not a table` coalescing warning during the SigNoz render; rendering completed, but this is not a policy-engine validation.
