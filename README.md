# Taranac on Kubernetes (K8s)

A declarative, GitOps-ready deployment of the **Taranac** Network Access Control (NAC), TACACS+, RADIUS, PKI, and EST/SCEP identity platform on Kubernetes using native Kustomize.

## Architecture Overview

Taranac is deployed across dedicated stateful and satellite workloads inside the `taranac` namespace:

```
                                 [ MetalLB Shared VIP ]
                               (e.g., 192.168.1.50 / L2 Mode)
                                     |             |
                     TCP Ingress Ports              UDP Ingress Ports
                 (80, 443, 49, 6049, 8445, 8446)    (1812, 1813, 1814, 1815, 3799)
                                     |             |
                       +-------------+-------------+
                       |
                       v
         +─────────────────────────────────────────────────────────────+
         | StatefulSet: taranac-core-0                                 |
         |                                                             |
         |  • edge         - Nginx ingress proxy & Web UI gateway       |
         |  • api          - FastAPI application & management engine   |
         |  • tacacs       - tac_plus-ng authentication daemon          |
         |  • radius       - FreeRADIUS 3.2 enterprise AAA engine      |
         |  • nac          - FreeRADIUS 802.1X dynamic policy engine   |
         |  • est-gateway  - RFC 7030 EST & SCEP certificate gateway   |
         |  • winbind      - Active Directory / Samba identity sidecar |
         +─────────────────────────────────────────────────────────────+
                |                    |                     |
                | (Internal TLS/mTLS)|                     | (SQL asyncpg)
                v                    v                     v
      +──────────────────+  +──────────────────+  +──────────────────+
      | taranac-renderer |  |   taranac-mfa    |  |     postgres     |
      | Headless Chrome  |  | MFA TOTP service |  | PostgreSQL 16    |
      | PDF report engine|  | & token storage  |  | StatefulSet      |
      +──────────────────+  +──────────────────+  +──────────────────+
                ^                                          ^
                |            Shared State Volumes          |
                +──────────[ taranac-state-pvc ]───────────+
                                (RWX / 5Gi)
```

### Workload Inventory
* **`taranac-core` (StatefulSet):** Multi-container core engine pod containing 7 tightly coupled sidecars operating on a shared network namespace and local inter-process volume mounts.
* **`postgres` (StatefulSet):** PostgreSQL 16 Alpine database with WAL replication parameters and automated multi-database initialization hooks (creating `taranac` and `taranac_mfa`).
* **`taranac-frontend` (Deployment):** Static frontend React user interface served by Nginx.
* **`taranac-renderer` (Deployment):** Authenticated headless Chromium worker rendering dynamic PDF reports.
* **`taranac-mfa` (Deployment):** Microservice managing Multi-Factor Authentication state and TOTP token validation.
* **`taranac-vip-tcp` / `taranac-vip-udp` (Services):** Dual-stack LoadBalancer services bound to a unified external IP address via MetalLB IP-sharing annotations.

## Repository Structure

The repository separates vendor-agnostic resource definitions from site-specific credentials and network configurations using Kustomize:

```
.
├── .gitignore
├── README.md
├── base/
│   ├── kustomization.yaml             # Base manifest aggregation
│   ├── namespace.yaml                 # Namespace definition (taranac)
│   ├── storage.yaml                   # PVC definitions without hardcoded StorageClasses
│   ├── postgres.yaml                  # Database StatefulSet, Service, & init ConfigMap
│   ├── satellites.yaml                # Frontend, MFA, and Renderer Deployments & Services
│   ├── core.yaml                      # taranac-core multi-container StatefulSet
│   └── services.yaml                  # Generic LoadBalancer VIP service manifests
└── overlays/
    └── local/
        ├── kustomization.yaml         # Injects secrets, config, and environment patches
        ├── config.env.example         # Non-sensitive environment variables template
        ├── secrets.env.example        # Secret key and credential template
        ├── metallb-patch.yaml.example # VIP and MetalLB sharing annotation template
        └── storage-patch.yaml.example # Custom StorageClass patch template
```

## Helm Chart

A Helm chart equivalent to the Kustomize setup lives in [`charts/taranac`](charts/taranac) (bundled PostgreSQL subchart or external database, generated secrets, Keel support, load balancer/ingress/storage hooks). See its [README](charts/taranac/README.md).

```bash
helm dependency build charts/taranac
helm install taranac charts/taranac -n taranac --create-namespace --set config.domain=taranac.example.com
```

## Prerequisites

1. **Kubernetes Cluster:** Kubernetes 1.28+ (K3s, vanilla `kubeadm`, RKE2, or cloud-managed K8s).
2. **Storage Provisioner:**
   * A StorageClass supporting `ReadWriteOnce` (for PostgreSQL data) and `ReadWriteMany` (for shared certificates and backup state across pods, e.g., NFS Subdir Provisioner, Longhorn, or CephFS).
3. **Load Balancer:** MetalLB (L2 or BGP mode) or an equivalent load balancer supporting shared IP annotations.
4. **Tools:** `kubectl` with Kustomize support (`kubectl apply -k`), and `openssl`.

## Quickstart & Deployment

### 1. Clone the Repository

```bash
git clone https://github.com/daedalus01/taranac-k8s.git
cd taranac-k8s
```

### 2. Prepare Environment Configurations
Copy all tracked template files to generate your local, untracked working files:

```bash
cp overlays/local/config.env.example overlays/local/config.env
cp overlays/local/secrets.env.example overlays/local/secrets.env
cp overlays/local/metallb-patch.yaml.example overlays/local/metallb-patch.yaml
cp overlays/local/storage-patch.yaml.example overlays/local/storage-patch.yaml
```

### 3. Generate Cryptographic Credentials
Edit `overlays/local/secrets.env`. Populate the required cryptographic keys and database passwords.

> **Warning:** Do **not** wrap values in quotation marks inside `.env` files. Kustomize injects quotation marks literally into the resulting Kubernetes secret payloads.

You can automatically generate secure random keys using standard OpenSSL utilities:

```bash
# 1. Database Password
POSTGRES_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9!#%')

# 2. Master Key (32-byte base64 string)
MASTER_KEY=$(openssl rand -base64 32)

# 3. 64-character Hex Keys
TARANAC_MFA_API_KEY=$(openssl rand -hex 32)
SECRET_KEY=$(openssl rand -hex 32)
EST_PROXY_KEY=$(openssl rand -hex 32)

# 4. Reports Renderer API Key (MUST be at least 32 characters)
REPORTS_RENDERER_API_KEY=$(openssl rand -hex 32)

cat <<EOF > overlays/local/secrets.env
POSTGRES_PASSWORD=${POSTGRES_PASS}
MASTER_KEY=${MASTER_KEY}
TARANAC_MFA_API_KEY=${TARANAC_MFA_API_KEY}
SECRET_KEY=${SECRET_KEY}
EST_PROXY_KEY=${EST_PROXY_KEY}
REPORTS_RENDERER_API_KEY=${REPORTS_RENDERER_API_KEY}
EOF
```

### 4. Configure Networking & Storage Patches
* **`overlays/local/config.env`:** Set your primary domain, extra SANs, and local timezone.
* **`overlays/local/metallb-patch.yaml`:** Replace `192.168.1.50` with your desired network VIP.
* **`overlays/local/storage-patch.yaml`:** Set `storageClassName` to match your cluster's storage provider (e.g., `nfs-client`, `local-path`, or `longhorn`).

### 5. Validate via Dry Run
Verify the assembled manifests and secret decoding prior to applying to the cluster:

```bash
# Verify secret encoding without quotes
kubectl kustomize overlays/local | awk '/POSTGRES_PASSWORD:/ {print $2}' | base64 -d; echo

# Run server-side validation against cluster admission controllers
kubectl apply -k overlays/local --dry-run=server
```

### 6. Apply Live
```bash
kubectl apply -k overlays/local
```

Monitor pod rollout:
```bash
kubectl get pods -n taranac -w
```

---

## Critical Operational & Architectural Details

### 1. Pydantic 32-Character Key Validation (`taranac-renderer`)
The report generator validates its application settings via Pydantic at boot time. If `REPORTS_RENDERER_API_KEY` is fewer than 32 characters, the Uvicorn worker process will fail with an unhandled `ValidationError` (`String should have at least 32 characters`) and crash-loop with exit code 3. Always supply a 32-byte (64-character hex) key.

### 2. Internal CA Trust & Renderer State Mount
The FastAPI `api` container communicates with `taranac-renderer` over TLS on port 8443, validating certificates against `/opt/taranac/certs/ca.crt`.
* `taranac-renderer` must mount `taranac-state-pvc` (subpath: `certs`) to `/opt/taranac/certs`.
* Environment variables `REPORTS_RENDERER_TLS_CERT` and `REPORTS_RENDERER_TLS_KEY` must point to `/opt/taranac/certs/renderer/server.crt` and `server.key`.
* If the state volume is omitted, the renderer falls back to an ephemeral self-signed certificate, which the backend will reject with an SSL handshake verification failure (surfacing as a `502 Bad Gateway` toast in the web interface during PDF generation).

### 3. Kubernetes Dependent Variable Expansion (`$(POSTGRES_PASSWORD)`)
Kubernetes supports nested variable substitution (such as `postgresql://taranac:$(POSTGRES_PASSWORD)@postgres:5432/taranac`), but only if the referenced variable is declared **above** the dependent variable in the container's `env:` block. If `POSTGRES_PASSWORD` is not explicitly declared in the container's environment first, Kubernetes injects the literal string `"$(POSTGRES_PASSWORD)"`, causing database authentication to fail.

### 4. Dynamic Nginx Template Rendering & Cluster DNS Resolution
The upstream container images use entrypoint scripts that dynamically render Nginx configurations from `/etc/nginx/templates/` via `envsubst` to prevent crash-loops before certificates are minted.
* A background file watcher periodically scans `/mnt/nac_config/certs` and re-runs `render()`.
* Direct inline edits to `/etc/nginx/conf.d/` will be overwritten whenever certificates update or reload.
* The manifests utilize `postStart` lifecycle hooks that update the source template files (`/etc/nginx/templates/*.template`) with the internal CoreDNS IP and FQDNs (`*.taranac.svc.cluster.local`) so re-rendered configs persist across trust updates.
* **DNS Note for Non-K3s Clusters:** In K3s, CoreDNS is deployed at `10.43.0.10`. In standard `kubeadm` deployments, CoreDNS typically resides at `10.96.0.10`. Run `kubectl get svc -n kube-system kube-dns` to verify your cluster's DNS IP and update the `postStart` hooks in `base/core.yaml` and `base/satellites.yaml` if your cluster uses a different Service CIDR.

### 5. Kustomize Strategic Merge Patch Scoping
Kustomize targets patch resources by `(Group, Version, Kind, Namespace, Name)`. Because the base manifests specify `namespace: taranac`, all patch overlays (`metallb-patch.yaml`, `storage-patch.yaml`) must explicitly include `namespace: taranac` under their `metadata:` block. Omitting the namespace causes Kustomize to search for an unscoped resource (`[noNs]`) and abort with `failed to find unique target for patch`.

---

## Verifying Endpoints

Once deployed and assigned your VIP:

```bash
VIP="192.168.1.50"

# 1. Web UI & Edge Gateway (HTTP -> HTTPS redirect)
curl -k -I "https://${VIP}"

# 2. RFC 7030 EST CA Retrieval
curl -k -v "https://${VIP}:8445/.well-known/est/cacerts"
# Expected (if unconfigured): HTTP 422 {"detail":"EST enrollment is not enabled..."}

# 3. SCEP CA Inspection
curl -v "http://${VIP}:8446/scep?operation=GetCACert"
# Expected (if unconfigured): HTTP 422 {"detail":"SCEP enrollment is not enabled..."}

# 4. Report Renderer Health (executed from inside the api container)
kubectl exec -n taranac taranac-core-0 -c api -- curl -s -o /dev/null -w "%{http_code}\n" \
  --cacert /opt/taranac/certs/ca.crt \
  -H "X-API-Key: $(kubectl get secret taranac-secrets -n taranac -o jsonpath='{.data.REPORTS_RENDERER_API_KEY}' | base64 -d)" \
  https://taranac-renderer:8443/api/v1/health
# Expected: 200
```