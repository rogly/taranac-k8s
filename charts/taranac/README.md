# taranac Helm chart

Deploys the Taranac NAC / TACACS+ / RADIUS / PKI / EST-SCEP platform. It is the
Helm equivalent of the Kustomize setup in the repository root.

```bash
helm install taranac ./charts/taranac -n taranac --create-namespace \
  --set config.domain=taranac.example.com
```

Out of the box this installs the core StatefulSet, the frontend, renderer and
MFA Deployments, a bundled PostgreSQL (Bitnami subchart), generated application
secrets, a shared state PVC on the default StorageClass, an Ingress for the web
UI, and a LoadBalancer Service (TCP and UDP) for TACACS+, EST, SCEP, RADIUS
and NAC. Nothing cluster-specific is set; use the hooks below.

Released versions are published as an OCI artifact to GitHub Container Registry
(`<owner>`/`<repo>` below is the GitHub repository that publishes the chart):

```bash
helm install taranac oci://ghcr.io/<owner>/charts/taranac --version <version> \
  -n taranac --create-namespace --set config.domain=taranac.example.com
```

To release, bump `version` in `Chart.yaml`, merge, then push a tag named
`taranac-<version>` (for example `taranac-0.1.0`); the `Helm chart` workflow
lints, packages, pushes and signs it (keyless, cosign). The tag must match the
chart version. Verify a download with
`cosign verify ghcr.io/<owner>/charts/taranac:<version> --certificate-identity-regexp 'https://github.com/<owner>/<repo>/' --certificate-oidc-issuer https://token.actions.githubusercontent.com`.

## Requirements

* Kubernetes 1.26+, Helm 3.8+ (OCI dependencies).
* A default StorageClass (any access mode). The shared state volume is
  ReadWriteOnce by default and the pods that mount it are co-scheduled on one
  node; with an RWX class set `persistence.state.accessModes={ReadWriteMany}`
  to let them spread out.
* An ingress controller (the web UI is served through an Ingress; there is no
  built-in proxy) and a LoadBalancer implementation (or set `service.*.type`).

Run `helm dependency build charts/taranac` once if you install from a checkout.

## Dependencies

### Helm subcharts

| Subchart | Version | Repository | Enabled by | Purpose |
| --- | --- | --- | --- | --- |
| `postgresql` (Bitnami) | `18.x.x` | `oci://registry-1.docker.io/bitnamicharts` | `postgresql.enabled` (default `true`) | Application and MFA databases |

The published chart already bundles the subchart; `helm dependency build`
(above) is only needed when installing from a checkout. Set
`postgresql.enabled=false` and fill in `externalDatabase` to use your own
PostgreSQL (including CloudNativePG) instead; see [Database](#database). Values
for the subchart go under the `postgresql:` key. Bitnami currently publishes
only `latest` images, so pin `postgresql.image.*` if you need a fixed
PostgreSQL major version.

### Cluster components

These are not installed by the chart. Only the first two are needed for a
default install.

| Component | Needed for | If missing |
| --- | --- | --- |
| Ingress controller | Web UI (`ingress.enabled`) | Disable the Ingress and route to the `frontend` Service yourself |
| LoadBalancer implementation (MetalLB, cloud LB) | TACACS+/RADIUS/NAC/EST/SCEP address (`service.*`) | Use `service.*.type=NodePort` or `ClusterIP` |
| Default StorageClass | State, data, MFA and database volumes | Set `persistence.*.storageClass` |
| cert-manager | Web certificate (`ingress.certManager`) | Provide `ingress.tls` yourself |
| CNI with NetworkPolicy support | Enforcing `networkPolicy` | Policies are created but not enforced; set `networkPolicy.enabled=false` to omit them |
| Keel | Automatic image updates (`keel.*`) | Leave `keel.enabled=false` |
| CloudNativePG operator | An in-cluster HA database | Use the bundled subchart or another external PostgreSQL |

## Common customisation

| Need | Values |
| --- | --- |
| Load balancer IP / annotations (e.g. MetalLB shared IP) | `service.tcp.*`, `service.udp.*` (`annotations`, `loadBalancerIP`, `loadBalancerClass`, `externalTrafficPolicy`, `ports`) |
| NodePort / ClusterIP instead of LB | `service.tcp.type`, `service.udp.type` |
| Web UI host, class, annotations, TLS | `ingress.*`, `config.domain` (see below) |
| Storage | `persistence.state.*`, `postgresql.primary.persistence.*` |
| Private registry / mirror | `global.imageRegistry`, `imagePullSecrets`, per-component `image.*` |
| Resources, security contexts, scheduling | per-component `resources`, `securityContext`, `nodeSelector`, ... |
| Extra env from a ConfigMap/Secret | per-component `extraEnv`, `extraEnvFrom` |

## Web UI and TLS

Taranac's own edge proxy is not deployed. The Ingress routes straight to the
`frontend` Service (plain HTTP), which serves the UI and proxies `/api`, so TLS
terminates at the Ingress. The host defaults to `config.domain`; the cluster's
default IngressClass is used unless `ingress.className` is set.

Your controller must provide what Taranac relies on (settings shown are
ingress-nginx's; use your controller's equivalents):

* **Body size:** 25 MB for collector uploads (`/api/v1/ncm/collector/*`). The
  frontend itself caps every other API path at 3 MB.
* **Timeouts:** 600 s read/send for bulk operations.
* **Trustworthy forwarded headers.** Without the edge nothing overwrites
  `X-Forwarded-For/Proto/Host/Port` or `X-Real-IP`, yet the core builds
  collector and portal URLs and records client IPs from them. A controller that
  accepts these from clients lets anyone choose them. ingress-nginx does so
  when `use-forwarded-headers` is `"true"` with a broad `proxy-real-ip-cidr`
  (such as `0.0.0.0/0`): we saw a client-supplied `X-Forwarded-Host` become the
  upstream `Host`, `X-Real-IP` and `X-Forwarded-Port` follow client values, and
  `X-Forwarded-Proto: http` redirect to an attacker-chosen host. Unless the
  controller sits behind a trusted L7 proxy or CDN, leave `use-forwarded-headers`
  off; if it does, restrict `proxy-real-ip-cidr` to that proxy's addresses.
  Check by sending spoofed headers to an echo service behind the same class.

```yaml
ingress:
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "25m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  certManager:               # cert-manager issues and renews the certificate
    enabled: true
    clusterIssuer: letsencrypt-production
```

`certManager` adds the issuer annotation and a TLS entry for every host
(Secret `<release>-taranac-tls`). To manage TLS yourself, leave it off and set
`ingress.tls` to a standard Ingress TLS list. Standalone collectors and captive
portals that pinned a previous certificate must be re-pointed at the new one.

TACACS+ (49, 6049), EST (8445, mutual TLS verified by the gateway itself) and
SCEP (8446) are not web traffic and stay on the `-vip-tcp` Service; RADIUS and
NAC stay on `-vip-udp`.

## Database

Default: the bundled PostgreSQL subchart. Its password is generated by the
subchart; the `taranac_mfa` database is created by an init script on first start.

To use an external server set `postgresql.enabled=false` and describe it in
`externalDatabase`. Each detail may come from an inline value, a ConfigMap or a
Secret (precedence: inline/URI > ConfigMap > Secret > default):

```yaml
# Discrete fields
externalDatabase: {host: db.internal, user: taranac, name: taranac, password: "..."}

# Inline URI (password is moved into the chart Secret; must be URL-safe)
externalDatabase: {uri: "postgresql://taranac:pw@db.internal:5432/taranac"}

# CloudNativePG: reuse the generated <cluster>-app Secret
externalDatabase:
  existingSecret: my-cluster-app
  existingSecretKeys: {host: host, port: port, user: user, name: dbname}

# Non-sensitive parts from a ConfigMap, password from a Secret
externalDatabase: {existingConfigMap: db-conn, existingSecret: db-creds}
```

The MFA database (`database.mfaName`, default `taranac_mfa`) must already exist
on an external server. The three consumers need different URL schemes
(`postgresql+asyncpg://` vs `postgresql://`) and the MFA service uses a
different database, so a URI stored in a Secret is not consumed; supply
discrete keys instead. The bundled PostgreSQL user is not a superuser (the
Kustomize setup used one); if Taranac needs extensions requiring superuser,
create them out of band.

## Secrets

`MASTER_KEY`, `SECRET_KEY`, `EST_PROXY_KEY`, `TARANAC_MFA_API_KEY` and
`REPORTS_RENDERER_API_KEY` are generated on first install and preserved across
upgrades. Override with `secrets.values.<KEY>` or bring your own Secret with
`secrets.existingSecret`. **Back up `MASTER_KEY`.** Tools that cannot `lookup`
(Argo CD, `helm template`) regenerate generated keys on every render, so use
`secrets.values` or `existingSecret` with them.

## Keel

* **Kubernetes provider:** `--set keel.enabled=true` adds `keel.sh/policy`,
  `trigger`, `pollSchedule`, `match-tag` (plus `approvals`, `notify` and
  `keel.annotations` when set) to the Taranac workloads. Images default to the
  release in `appVersion`, so the defaults (`policy: minor`, `matchTag: false`)
  follow semver releases. To track a moving tag instead: `--set image.tag=latest
  --set keel.policy=force --set keel.matchTag=true`. Keel patches live
  workloads, so a later `helm upgrade` resets images unless you pass the
  current tags.
* **Helm provider:** leave `keel.enabled=false` and use
  `-f examples/values-keel-helm.yaml`; Keel then upgrades the release itself.

Use one provider, not both. Keel does not manage the PostgreSQL subchart.

## Notes

* The images address `api`, `frontend`, `taranac-renderer` and `taranac-mfa` by
  fixed Service names, so run one release per namespace. Pod selectors differ
  from the Kustomize manifests, so migrating means recreating the workloads.
* The `postStart` hooks that point nginx at cluster DNS read the resolver from
  the pod's `resolv.conf`; no Service CIDR setting is needed (`dnsResolver`
  overrides it).
* `core.hostEtc.enabled` (off by default) mounts the node's `/etc` read-only
  into the `api` container for the host-monitoring page; it needs a hostPath
  volume, which restricted Pod Security levels reject.
* Logs and uploaded vendor RADIUS dictionaries live on a second PVC
  (`persistence.data`, RWO, core pod only); the certificates and backups live on
  the shared state PVC.
* The probes: the api has startup/readiness/liveness probes on `/healthz`; the
  frontend waits for the internal CA (init container) and the renderer for its
  certificate. Daemons (tacacs, radius, nac, winbind, est-gateway) have no
  probes because the images ship none.
* `networkPolicy.enabled` (default) restricts the api, renderer and mfa to Taranac
  pods (the daemons' client ports stay open). Add Ingress/phone peers for mfa via
  `mfa.extraIngress`. Only enforced by a policy-capable CNI; set false to disable.
* `service.combined` (default) serves TCP and UDP from one LoadBalancer Service
  (`<release>-vip`), so one address without sharing annotations. Needs
  Kubernetes >= 1.26 and a mixed-protocol load balancer; set false for separate
  TCP and UDP Services.
* The api sees its keys in `/app/host/env` (for backup/restore) when the Secret
  is chart-managed; with `secrets.existingSecret` that file is not provided, so
  keep your own backup of the keys.

## Operating it the Kubernetes way

| Compose | Here |
|---|---|
| `update.sh` | `helm upgrade`, or Keel |
| volume backups | Velero/CSI snapshots of both PVCs, plus the database (CloudNativePG, `pg_dump`) |
| `.env` secrets | the chart Secret; back up `MASTER_KEY` |
| HA (Patroni/etcd) | not mapped: use an HA external database (e.g. CloudNativePG) |

RADIUS CoA is sent from the pod/node address, not the load balancer address.
If your switches only accept CoA from the address they authenticate against,
use `externalTrafficPolicy: Local` plus a load balancer that preserves egress
IP, or run the core on a dedicated node.

### Needs changes in the application, not the chart

* The nginx images hard-code the Compose resolver and `api` upstream; the chart
  patches them with `postStart` hooks (an env-var driven config would replace
  that).
* The core pod runs six daemons that coordinate through shared files and unix
  sockets, so it cannot be split into independently scaled Deployments.
* Per-image security contexts (non-root, read-only root filesystem) are not
  set by default because the images have not been validated with them.

* The Bitnami PostgreSQL chart currently publishes only `latest` images
  (PostgreSQL 18 at the time of writing). Pin `postgresql.image.*` to the major
  version you intend to keep, or use an external database.
