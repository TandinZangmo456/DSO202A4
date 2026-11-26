<!--
README.md
Assignment: DSO202 A4 (GitOps delivery of the Task Tracker with Argo CD)
Descriptor: 4.1-4.4
Purpose: what this repository is, how to rebuild it, and answers to Q1-Q6.
-->
# dso202-gitops

GitOps delivery of the three-tier Task Tracker (Assignments 1–3) with Argo CD.
Argo CD runs in the cluster, reads this repository, and keeps two environments
matching it:

| | dev | staging |
|---|---|---|
| Namespace | `dso202-dev` | `dso202-staging` |
| Application | `tasktracker-dev` | `tasktracker-staging` |
| Follows | branch `main` | a Git tag (`v1.0.0` → `v1.1.0` → `v1.2.0`) |
| Sync | automated, prune + self-heal | manual (promotion gate) |
| Frontend | NodePort 30080 → `http://localhost:30080` | NodePort 30081, via `kubectl port-forward` |
| Credentials | SealedSecret in `platform/dev/` | separate SealedSecret in `platform/staging/` |

Command output for every task is in [`docs/evidence.md`](docs/evidence.md).

## Repository layout

```text
.gitignore                 keeps plaintext and key backups out of Git (first commit)
cluster/kind-cluster.yaml  kind cluster "dso202-gitops", host port 30080
bootstrap/argocd/          Argo CD v3.5.6 via Kustomize + settings/RBAC patches   (applied by hand)
bootstrap/root/            platform AppProject + root Application                (applied by hand)
argocd/projects/           dso202 AppProject                         (delivered by root, wave -3)
argocd/applications/       sealed-secrets (-2), platform-* (-1), tasktracker-* (0)
platform/dev|staging/      namespace, quota + limits, Kubernetes RBAC, SealedSecret
charts/tasktracker/        the Assignment 3 chart, adjusted to contract C1–C11
environments/dev|staging/  values files - only the differences between environments
docs/evidence.md           evidence for Tasks 1–10
```

Only `bootstrap/` is ever applied by hand. Everything else reaches the cluster
because the `root` Application pulls it from `main`.

## Pinned versions

| Component | Version |
|---|---|
| Argo CD / `argocd` CLI | v3.5.6 |
| Sealed Secrets chart / controller / `kubeseal` | 2.20.0 / 0.40.0 / v0.40.0 |
| Task Tracker images | `sarojsanyasi/dso202-{frontend,backend,db}` tags `1.0`, `1.1` only |
| Smoke-test image | `busybox:1.37` |
| kind, node image, kubectl | as in Practical 1 |
| Helm | as in Assignment 3 |

`latest`, `stable`, `master` and `HEAD` are never used as a version.

## Rebuild from an empty machine

Prerequisites: Docker (≥ 6 GB memory), kind, kubectl, Helm, git, `argocd`
v3.5.6, `kubeseal` v0.40.0, and the sealing-key backup kept outside this repo.

```bash
git clone https://github.com/TandinZangmo456/dso202-gitops.git && cd dso202-gitops

# 1. cluster + images (images are loaded from the host, not pulled in-cluster)
kind create cluster --config cluster/kind-cluster.yaml
../dso202-a4/scripts/load-images.sh          # or: kind load docker-image <img> --name dso202-gitops

# 2. restore the sealing key BEFORE the controller starts
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key-latest.yaml

# 3. bootstrap layer (the only hand-applied files)
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl -n argocd rollout status deploy --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl apply -f bootstrap/root

# 4. wait for root to create everything in waves, then sync staging by hand
kubectl -n argocd get applications -w
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure \
  --password "$(argocd admin initial-password -n argocd | head -1)"
argocd app sync tasktracker-staging

# 5. check
curl -s http://localhost:30080 | head -5
kubectl -n dso202-staging port-forward svc/tasktracker-frontend 8081:8080
```

## Cleanup

```bash
kind delete cluster --name dso202-gitops
docker image prune -f        # optional
```

The sealing-key backup in `../dso202-keys/` is kept: it is the only way to
decrypt the SealedSecrets in this repository on a new cluster.

## Credential handling

- Database credentials exist in Git **only** as SealedSecrets
  (`platform/<env>/tasktracker-credentials.sealed.yaml`), encrypted with the
  cluster's public key and scoped strictly to Secret `tasktracker-credentials`
  in its own namespace. Dev and staging use different passwords.
- The chart never renders a Secret (C3). Pods read the Secret the controller
  decrypts, through `existingSecret: tasktracker-credentials`.
- Plaintext was created in a git-ignored `secrets-plain/` folder, piped
  through `kubectl create secret --dry-run | kubeseal` (no plaintext manifest
  on disk), then deleted. A search of the full Git history for every value,
  plain and base64, returned no match (Task 4 evidence).
- The sealing key is backed up to `../dso202-keys/` (mode 600), outside the
  repository, again after every rebuild. `.gitignore` is a second safety net,
  not the protection itself.

## Answers

### Q1 – Why is `platform` applied by hand while `dso202` is created by root?

`root` needs a project before it can exist, and an Application cannot create
the project it belongs to. `platform` is therefore part of the bootstrap
layer, applied once by an administrator together with `root`. It is the
trusted, high-privilege project: all kinds, and the only one allowed to target
`argocd`. `dso202` is an ordinary workload project, so it is just another file
in `argocd/`, created by root in wave -3 and changed through pull requests like
everything else.

If `dso202` were allowed to deploy into `argocd`, a commit to the chart (which
developers change often) could create or change `Application`, `AppProject` or
`ConfigMap` objects in the Argo CD namespace — for example a new Application in
the `platform` project, or a patched `argocd-rbac-cm`. That is privilege
escalation: a workload change could widen its own permissions or take control
of the whole cluster through Argo CD. Keeping the two projects separate means a
bad chart commit can only affect the two workload namespaces and only the six
whitelisted kinds.

### Q2 – What does strict sealed-secret scope prevent, and what if the key is lost?

Strict scope binds the namespace and the Secret name into the encryption. The
controller will only decrypt our file as `tasktracker-credentials` in
`dso202-dev` (or `dso202-staging`). Copying the dev SealedSecret into staging,
into another namespace, or renaming it fails to decrypt. So someone who can
create objects in another namespace cannot reuse our ciphertext to read the
database password there, and the dev credentials can never accidentally be
used by staging.

If the sealing key is lost (cluster deleted without a backup), every
SealedSecret in Git becomes unreadable: a new controller generates a new key
and cannot decrypt them, so `platform-*` stay Degraded and the database Pods
cannot start. The ciphertext in Git is permanently useless. Recovery: install
the controller, recreate the plaintext credentials (from the running database
or by rotating them), seal them again with the new public key, commit the new
files, and back up the new key straight away. For an existing database the new
password must match the one stored in PostgreSQL, or the password must be
changed inside the database too.

### Q3 – Synced vs Healthy

**Synced** compares Git with the cluster: the live objects match what the
chart renders at the target revision. **Healthy** describes whether those
objects actually work: a Deployment has its available replicas, a StatefulSet
is rolled out, a Job succeeded.

An application can be Synced but not Healthy. In Task 7 Part B, after the
faulty backend `1.1` was merged, `tasktracker-dev` was Synced — the
Deployment in the cluster had exactly the image Git asked for — but the new
backend Pod never became Ready, so the app was Progressing and then Degraded
once `progressDeadlineSeconds: 120` (C6) expired. Another way to provoke it:
set a tag that does not exist (or remove an image from the kind node) — Argo CD
applies it (Synced), the Pod sits in `ErrImagePull`, and health is Degraded.
Before the first manual sync in Task 5, staging showed the opposite pairing:
OutOfSync and Missing, and `root` reported that child health upward.

### Q4 – Argo CD RBAC vs Kubernetes RBAC

Argo CD RBAC controls what a person or token may do **through Argo CD** (API,
UI, CLI): which Applications and projects they can see, sync, delete, read logs
of, and so on. It is configured in `argocd-rbac-cm` (`policy.csv`,
`policy.default`) — here in `bootstrap/argocd/argocd-rbac-cm-patch.yaml` — and
the accounts in `argocd-cm`. Argo CD itself then acts on the cluster with its
own ServiceAccounts.

Kubernetes RBAC controls what a user or ServiceAccount may do **directly
against the Kubernetes API** (`kubectl`). It is configured with Role /
ClusterRole and RoleBinding / ClusterRoleBinding objects — here
`platform/<env>/rbac.yaml` (read-only access for `task-tracker-readers`) plus
the ClusterRoles installed with Argo CD. The two are independent: the
`reviewer` account cannot use `kubectl` at all, and a `kubectl` user with
cluster-admin is not limited by `policy.csv`.

With SSO, Argo CD would receive the user's groups from the identity provider
in the token. `policy.csv` would then grant permissions to groups instead of a
local account, and the local `reviewer` account would be removed:

```csv
p, role:reviewer, applications, get, dso202/*, allow
p, role:reviewer, projects,     get, dso202,   allow
p, role:reviewer, logs,         get, dso202/*, allow
g, dso202-reviewers, role:reviewer      # IdP group -> Argo CD role
```

(`scopes: '[groups]'` in `argocd-rbac-cm` tells Argo CD which claim holds the groups.)

### Q5 – Why is rollback refused, and what is the GitOps equivalent?

`argocd app rollback` deploys an older revision from the app's history
directly. With automated sync that would immediately conflict with Git: Git
still says "backend 1.1", so the next reconciliation would re-apply the faulty
version. Argo CD refuses rather than fight itself, and it would also break the
rule that Git is the single source of truth.

The GitOps equivalent is to change Git: `git revert <bad-sha>` creates a new
commit that undoes the faulty one; Argo CD pulls it and returns dev to the
last good state. `git revert` is preferred over deleting the bad commit
(`reset` + force-push) because history is kept and never rewritten: the
faulty change, its revert, and the fix stay visible and auditable; tags such
as `v1.1.0` and everyone else's clones stay valid; and no force-push to a
protected `main` is needed. Deleting the commit would hide what happened and
could make Argo CD and other clones point at commits that no longer exist.

### Q6 (a) – One repository for chart and environment config

Advantages:
1. One pull request can change the chart and the values that use it together,
   and one tag (`v1.2.0`) pins both — staging always gets a chart and values
   that were tested together.
2. Simple to set up and to rebuild: one URL, one set of credentials for Argo
   CD, one place to search and review.

Disadvantages:
1. Everyone who can change the chart can also change staging's values (and
   the reverse); access cannot be split per environment or per team.
2. Every commit — even a dev-only values change — creates a new revision for
   every Application and is mixed into one history; promotion by tag also
   carries unrelated chart changes along. The bonus multi-source setup (Task
   10) is one step towards separating the two.

### Q6 (b) – What sits outside GitOps control after a rebuild?

| Item | Why it is outside | How production teams handle it |
|---|---|---|
| Bootstrap layer (`bootstrap/argocd`) | Argo CD cannot install itself before it exists; changes (e.g. the Task 6 logs rule) need a hand `kubectl apply -k`. | Install Argo CD with Terraform/Helm in the cluster-creation pipeline, or let Argo CD manage its own installation after the first bootstrap (self-managed Argo CD). |
| Root Application and `platform` project | Applied by hand; nothing re-creates them if they are deleted. | Created by the same IaC/bootstrap pipeline, protected by RBAC, often with deletion protection. |
| Sealing key | It is a secret, so it can never be in Git; without it the SealedSecrets are useless. | Store it in a vault/KMS or a cloud secrets manager with access control and rotation, or use External Secrets with a central secret store instead of sealing per cluster. |
| Database contents | Git describes the StatefulSet, not the rows in PostgreSQL. A rebuilt cluster gets an empty volume. | Scheduled database backups (pg_dump, WAL archiving, volume snapshots/Velero), a managed database service, and tested restore procedures. |
