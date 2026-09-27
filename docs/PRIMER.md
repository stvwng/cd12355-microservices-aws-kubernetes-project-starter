# Coworking Space on EKS: Primer

Sep 26, 2026 · @Steve Wang

This project shipped a Flask analytics API to AWS EKS: GitHub push triggers CodeBuild, CodeBuild pushes a semver-tagged image to ECR, Kubernetes manifests run it beside Postgres, and CloudWatch Container Insights collects its logs. Each section below covers one layer, then the lessons from the problems actually hit.

## The big picture

The system splits into two loops: a build loop that turns commits into images, and a run loop that turns images into running pods. They meet at ECR.

```
 BUILD LOOP (automatic)                          RUN LOOP (you decide when)

  git push main                                   scripts/03-deploy.sh 1.0.N
       |                                                   |
       v                                                   v
 +-----------+  webhook  +-----------+  push   +-------+  pull  +------------------------------+
 |  GitHub   | --------> | CodeBuild | ------> |  ECR  | -----> |  EKS cluster                  |
 +-----------+           | buildspec |  1.0.N  | repo  |        |                               |
                         +-----------+         +-------+        |  LoadBalancer Svc :5153       |
                                                                |        |                      |
                                                                |        v                      |
                                                                |  coworking pod (Flask)        |
                                                                |        |  env: ConfigMap+Secret|
                                                                |        v                      |
                                                                |  postgresql-service :5432     |
                                                                |        |                      |
                                                                |        v                      |
                                                                |  postgresql pod --> PV/PVC    |
                                                                |                               |
                                                                |  Fluent Bit --> CloudWatch    |
                                                                +------------------------------+
```

The life of one request:

1. A client calls the ELB hostname on port 5153; AWS created that ELB because the Service type is `LoadBalancer`.
2. The ELB forwards to a node port, and kube-proxy routes it to a pod whose labels match the Service `selector` (`service: coworking`).
3. Flask reads DB settings from environment variables injected from the ConfigMap and Secret, and connects to `postgresql-service`, a DNS name that cluster DNS resolves to the Postgres pod.
4. The response goes back the same way; anything the app prints to stdout or stderr is tailed by Fluent Bit into CloudWatch.

The key idea: every arrow is decoupled. CodeBuild knows nothing about Kubernetes, and Kubernetes knows nothing about GitHub. The image tag is the only contract between them.

## Containers: the Dockerfile

A Dockerfile is a recipe of layers; each instruction produces a cached layer, and Docker rebuilds only from the first changed layer downward. Order instructions from least to most frequently changed.

```dockerfile
FROM public.ecr.aws/docker/library/python:3.10-slim-bookworm   # 1. base image
ENV PYTHONUNBUFFERED=1                                          # 2. runtime behavior
WORKDIR /app
COPY analytics/requirements.txt .                               # 3. deps manifest only
RUN pip install --no-cache-dir -r requirements.txt              # 4. cached until deps change
COPY analytics/ .                                               # 5. code changes land here
RUN useradd --create-home --uid 10001 appuser
USER appuser                                                    # 6. drop root
CMD ["python", "app.py"]
```

| Concept | What it means | Why it mattered here |
| --- | --- | --- |
| Base image choice | `slim` is Debian-based with glibc; `alpine` uses musl | `psycopg2-binary` ships glibc wheels, so slim installs in seconds while Alpine would compile from source |
| Registry of the base image | Pulling from `public.ecr.aws` instead of Docker Hub | Avoids Docker Hub anonymous pull rate limits inside CodeBuild |
| Layer caching | Copy `requirements.txt` and install before copying code | A code-only change skips the slow `pip install` layer |
| `PYTHONUNBUFFERED=1` | Python writes logs immediately instead of buffering | Health logs reach CloudWatch in real time, not in bursts |
| Non-root `USER` | The process runs as uid 10001 | A container escape lands as an unprivileged user |
| `.dockerignore` | Excludes `.git`, manifests, SQL, screenshots | Smaller build context, faster builds, no secrets baked in |
| Exec-form `CMD [...]` | Runs Python as PID 1 without a shell | Python receives SIGTERM directly, so pod shutdowns are clean |

Test the image locally before any cloud work: run Postgres in one container, the app in another on a shared Docker network, seed the DB, and `curl` the endpoints. That loop caught the config-name bug in minutes instead of after a 15-minute cluster build.

## CI: CodeBuild and ECR

CodeBuild is a managed build container that runs the commands in `buildspec.yml`; ECR is a private Docker registry. Four pieces must line up for a push to turn into an image.

```
  GitHub repo --(GitHub App via CodeConnections)--> CodeBuild project
      |                                                  |
      | webhook: PUSH on ^refs/heads/main$                | assumes IAM service role
      +------------------------> starts build ---------->+
                                                         | docker build / push
                                                         v
                                                    ECR repo "coworking"
```

| Piece | Role | What it needs |
| --- | --- | --- |
| Source credential | Lets CodeBuild clone the repo and register webhooks | A CodeConnections GitHub App connection, with the app installed on the GitHub account and granted the repo |
| Webhook | Fires a build on each matching push | Filter groups: `EVENT=PUSH` and `HEAD_REF=^refs/heads/main$` |
| Service role | The IAM identity the build runs as | ECR push actions scoped to the repo, `ecr:GetAuthorizationToken`, CloudWatch Logs, and `codeconnections:GetConnectionToken` |
| Privileged mode | Allows Docker-in-Docker inside the build container | `privilegedMode: true` on the environment, or `docker build` fails |

**buildspec phases.** `pre_build` logs Docker in to ECR (`aws ecr get-login-password | docker login`) and computes the tag; `build` runs `docker build`; `post_build` runs `docker push` and writes `imagedefinitions.json` for any later deploy stage. A failing command stops the build at that phase.

**Semantic versioning.** Tags are `MAJOR.MINOR.PATCH`. Here `PATCH` is `$CODEBUILD_BUILD_NUMBER`, which auto-increments, so every build gets a unique tag with no manual step. Bump `MAJOR_MINOR` in the buildspec for a new feature (minor) or a breaking change (major).

**Immutable tags.** The ECR repo is set to `IMMUTABLE`, so pushing `1.0.1` twice is rejected. A tag therefore always names the same bytes, which makes rollback trustworthy; never deploy `latest`.

**Other ECR settings.** Scan-on-push checks each image for known CVEs, and a lifecycle policy keeps only the newest 10 images to cap storage cost.

**Least privilege.** The build role can push only to `repository/coworking`, not to every repo in the account. Note that creating or widening an IAM role is a permission grant; treat it as a reviewed change.

## Kubernetes objects

Kubernetes is declarative: you apply YAML describing the desired state, and controllers keep changing the cluster until it matches. Seven manifests in `deployment/` describe this whole app.

```
  Service coworking (LoadBalancer)        Service postgresql-service (ClusterIP)
        | selector: service=coworking            | selector: app=postgresql
        v                                        v
  Deployment coworking                     Deployment postgresql (strategy: Recreate)
    -> ReplicaSet -> Pod                     -> ReplicaSet -> Pod
         |  envFrom: ConfigMap coworking-config    |  env from same ConfigMap + Secret
         |  env DB_PASSWORD: Secret                |  volume: PVC postgresql-pvc
         |                                         v
         |                                  PV postgresql-pv (hostPath on node)
```

| Object | What it is | In this project |
| --- | --- | --- |
| Pod | One or more containers sharing a network namespace; the unit that runs | Never created directly; Deployments create them |
| Deployment | Desired pod template + replica count; manages ReplicaSets for rollouts | `coworking` (RollingUpdate) and `postgresql` (Recreate) |
| Service | A stable virtual IP and DNS name in front of pods chosen by label `selector` | `coworking` is `LoadBalancer`; `postgresql-service` is `ClusterIP` |
| ConfigMap | Non-sensitive key/value config | `DB_NAME`, `DB_USERNAME`, `DB_HOST`, `DB_PORT` |
| Secret | Sensitive values, base64-encoded (encoding, not encryption) | `DB_PASSWORD` |
| PersistentVolume | A piece of storage in the cluster | 1Gi `hostPath` on the node's disk |
| PersistentVolumeClaim | A pod's request for storage, bound to a PV | Bound by name via `volumeName` and `storageClassName: manual` |

**Service types.** `ClusterIP` (default) is reachable only inside the cluster, which is right for a database. `NodePort` opens a port on every node. `LoadBalancer` also asks the cloud for an external load balancer; on EKS that creates an AWS ELB. Services find pods by labels, so a typo in `selector` means a Service with zero endpoints.

**Config injection.** `envFrom: configMapRef` imports every key as an env var; `env.valueFrom.secretKeyRef` imports one key. Env vars are read only at container start, so changing a ConfigMap needs `kubectl rollout restart` to take effect.

**Probes.** The liveness probe (`/health_check`) answers "is the process alive?"; failing it restarts the container. The readiness probe (`/readiness_check`, which queries the DB) answers "can it serve traffic?"; failing it removes the pod from Service endpoints without restarting. Readiness is what makes rolling updates safe.

**Rollout strategies.** `RollingUpdate` starts the new pod before stopping the old one, so there is no downtime. `Recreate` stops the old pod first, which Postgres needs because two instances must never share one data directory.

**Requests and limits.** A request is what the scheduler reserves; a limit is the hard ceiling. Measured idle use was about 43Mi for the API and 37Mi for Postgres, so requests of 128Mi and 256Mi leave headroom. Memory limits stop a leak from starving the node (the pod is OOM-killed instead); CPU limits were omitted because CPU over-use only throttles, and throttling hurts latency more than it protects neighbors at this scale.

**Storage caveat.** A `hostPath` PV lives on one node's disk. If the Postgres pod reschedules to the other node, it starts with an empty directory. Production would use the EBS CSI driver with a dynamic `gp3` StorageClass, or managed RDS.

## EKS and eksctl

EKS runs the Kubernetes control plane for you; you run (and pay for) the worker nodes. eksctl turns one YAML file into the CloudFormation stacks that create both.

```
  +------------------ AWS-managed ------------------+
  |  EKS control plane: API server, etcd, scheduler  |   ~$0.10/hr flat
  +--------------------------+-----------------------+
                             | kubelet on each node talks to the API
  +------------------ your account ------------------+
  |  Managed node group: 2 x t3.small EC2 (in a VPC) |   per-instance hourly
  |   node IAM role: ECR pull, CNI, CloudWatch agent |
  |   DaemonSets: aws-node, kube-proxy, Fluent Bit,  |
  |               CloudWatch agent                    |
  +---------------------------------------------------+
```

| Concept | Meaning |
| --- | --- |
| `infra/cluster.yaml` | Declarative cluster spec: name, region, node group size and type, add-ons. Re-runnable and reviewable, unlike console clicks |
| Managed node group | EC2 instances that EKS patches and replaces for you; `minSize`/`maxSize` bound scaling |
| Node IAM role | Identity of every pod on the node unless you use pod identity. `withAddonPolicies.cloudWatch` attaches `CloudWatchAgentServerPolicy` |
| Add-on | An AWS-maintained cluster component, versioned with EKS. Here `amazon-cloudwatch-observability` (and `metrics-server`) |
| kubeconfig | `aws eks update-kubeconfig` writes a context whose auth runs `aws eks get-token`, so kubectl authenticates with your AWS identity |
| ECR pull | Nodes pull private ECR images using the node role's `AmazonEC2ContainerRegistryReadOnly`; no image pull secret needed |

**Why kubectl stopped working when SSO expired.** kubectl has no password of its own; every call shells out to the AWS CLI for a short-lived token. An expired SSO session breaks kubectl and AWS alike, so `aws sso login` fixes both.

**Pod identity vs node role.** eksctl warned that the CloudWatch add-on should get permissions through pod identity associations. Using the node role works, but it grants those permissions to every pod on the node. Pod identity scopes them to the add-on's service account, which is the least-privilege choice for production.

**Local rehearsal with kind.** `kind` runs Kubernetes inside Docker. Applying the same manifests there proved them correct before paying for EKS; only cloud-specific parts (the ELB, IAM, CloudWatch) needed the real cluster.

## Observability: Container Insights

Containers should log to stdout and stderr, and the platform should ship those streams; the app never talks to CloudWatch itself.

```
  app print/log --> container stdout/stderr --> /var/log/containers/*.log on the node
                                                        |
                                    Fluent Bit (DaemonSet, one per node) tails it
                                                        |
                                                        v
            CloudWatch log group /aws/containerinsights/<cluster>/application
              one log stream per container: <node>-application...<pod>_<ns>_<container>-<id>.log
```

- **Log group layout.** Container Insights creates `application` (your containers), `dataplane` (kubelet, kube-proxy), `host` (node OS) and `performance` (metrics as structured logs) groups per cluster.
- **Each event is JSON.** The original line sits in the `log` field beside `stream` and a `kubernetes` object (pod, namespace, labels). Filter on phrases inside it, such as `"INFO in app"`.
- **What "healthy" looks like here.** The scheduler's report every 30 seconds, plus `GET /health_check` and `GET /readiness_check` lines returning 200 roughly every 10 seconds from the kubelet probes.
- **The Flask warning is expected.** "This is a development server" means Flask's built-in server is in use. It is not an error; production would run gunicorn instead.

**The OpenTelemetry gotcha.** The CloudWatch observability add-on also auto-instruments workloads. It annotated the pod template with `instrumentation.opentelemetry.io/inject-python: true` and injected an OTel Python agent. That agent replaced Python's logging configuration, so the app's own log lines vanished and only the agent's "Exported N endpoint metrics" lines reached CloudWatch. It also added Java, Node.js and .NET init containers to a Python pod.

The fix was an explicit opt-out in the pod template, which the operator respects:

```yaml
template:
  metadata:
    annotations:
      instrumentation.opentelemetry.io/inject-python: "false"
      instrumentation.opentelemetry.io/inject-java: "false"
      instrumentation.opentelemetry.io/inject-nodejs: "false"
      instrumentation.opentelemetry.io/inject-dotnet: "false"
```

The lesson: a platform add-on can mutate your pods at admission time. When a pod differs from your YAML (extra init containers, new annotations), `kubectl describe` shows what was injected, and the add-on is the suspect.

## Releasing and rolling back

Building and releasing are separate decisions: every merge builds an image automatically, but an image reaches users only when you point the Deployment at its tag.

```
  merge to main --> CodeBuild --> ECR 1.0.7          (automatic)
                                     |
  scripts/03-deploy.sh 1.0.7  -------+               (deliberate)
      |  sed: image: .../coworking:1.0.7 into coworking.yaml
      |  kubectl apply -f coworking.yaml
      v
  Deployment revision N+1:  new pod starts --> readiness passes --> old pod stops
                             new pod fails readiness --> old pod keeps serving
```

1. **Release.** Merge, wait for the build, read the tag in its log, then run `scripts/03-deploy.sh 1.0.N` (no argument takes the newest ECR image).
2. **Watch.** `kubectl rollout status deploy/coworking` blocks until the new ReplicaSet is fully available, or fails after the timeout.
3. **Record.** Commit the updated `coworking.yaml` so git shows what is running (a lightweight GitOps habit).
4. **Roll back.** Re-run the deploy script with the previous tag. `kubectl rollout undo deploy/coworking` also works, but it leaves git out of step with the cluster.
5. **Config-only change.** Edit the ConfigMap or Secret, `kubectl apply` it, then `kubectl rollout restart deploy/coworking`, because env vars load only at start.

**Idempotent scripts.** Every script checks before it creates (`describe || create`), and the deploy seeds the database only when the `tokens` table is missing. Re-running after a partial failure is always safe, which is the property that makes automation trustworthy.

**Where this would go next.** CodePipeline could chain a deploy stage after the build using `imagedefinitions.json`, or a GitOps tool such as Argo CD could watch the manifest in git and apply it for you.

## Lessons learned

Every problem below actually happened on this project, in this order. Most were identity and permission issues rather than code bugs, which is typical of cloud work.

| Symptom | Root cause | Fix | Lesson |
| --- | --- | --- | --- |
| App would have crashed on start with `KeyError: 'DB_USERNAME'` | Starter ConfigMap used `DB_USER`, but `config.py` reads `DB_USERNAME` | Renamed the key | Read the code's env var names; do not trust a template |
| Every `aws` call failed: "Token has expired and refresh failed" | SSO sessions are short-lived | `aws sso login --profile sswang` | Check `aws sts get-caller-identity` first; it also confirms which account you are in |
| CodeBuild page said "You have not connected to GitHub" after creating a connection | A connection existed but was never set as a source credential for the project | Attach the connection to the project's source `auth` | A connection is a credential, not a binding; something must reference it |
| "Access denied to connection" | The CodeBuild service role lacked `codeconnections:GetConnectionToken` | Added connection actions to the role policy | The build runs as its role, not as you; your admin rights do not transfer |
| `OAuthProviderException: Failed to create webhook` | The AWS Connector GitHub App was never installed on the GitHub account | New connection via "Install a new app", granted this repo | "Available" in AWS does not mean GitHub granted anything; check GitHub's Installed Apps |
| Push blocked by a safety check | `secret.yaml` held a real password and the repo is public | Committed everything except the Secret; shipped it only in the zip | Base64 is not encryption; secrets stay out of git (use Secrets Manager or External Secrets) |
| App logs missing from CloudWatch | CloudWatch add-on injected an OTel agent that took over Python logging | Opt-out annotations on the pod template | Add-ons mutate pods; `kubectl describe` reveals injected containers |
| `command not found: kubectl --context kind-cw-test` | zsh does not word-split `$VAR`, unlike bash | Used a shell function instead of a string variable | Put commands in functions or arrays, never in strings |
| A wait loop never ended | `aws ... --query length(...)` printed one number per result page ("12" then "0") | Read the output once instead of comparing it | CLI `--query` applies per page on paginated calls |
| `screencapture` failed | The shell had no macOS screen-recording permission | Rendered real command output to images instead | Automation hits OS privacy gates; plan for manual steps |

**The general debugging move.** Each fix came from reading the exact error, then checking state directly (`describe`, `get-connection`, `list-source-credentials`, `kubectl logs`) instead of guessing. Hidden stderr (`2>/dev/null` in the bootstrap script) cost a round trip; surface errors, even in helper scripts.

## Sizing and cost

Left running, this stack costs roughly $120 a month, and most of it is fixed overhead rather than the app. The figures are approximate us-east-1 on-demand prices from memory, not a quote.

| Item | Approx. hourly | Approx. monthly | Notes |
| --- | --- | --- | --- |
| EKS control plane | $0.10 | $73 | Flat per cluster, even with zero pods |
| 2 x t3.small nodes | $0.042 | $30 | Plus about $3.20 for two 20 GB EBS root volumes |
| Classic ELB for the `LoadBalancer` Service | $0.025 | $18 | Plus data processed |
| CloudWatch logs | usage | a few dollars | Ingestion per GB; default retention is forever |
| ECR storage | usage | cents | Lifecycle policy keeps 10 images |
| CodeBuild | per build-minute | cents | About 1 minute per build on the small instance |

**Why t3.small.** The API is I/O-bound and idle almost always, so burstable CPU credits fit it. 2 GiB per node holds the app, Postgres and the monitoring DaemonSets, and two nodes leave room for a surge pod during rolling updates.

**Cost levers, biggest first.**

- Tear down when idle: `scripts/99-teardown.sh` removes the control plane, nodes and ELB, which is nearly the whole bill.
- Share one load balancer across services with the AWS Load Balancer Controller and an Ingress, instead of one ELB per `LoadBalancer` Service.
- Use Spot instances for non-production node groups, and Graviton (`t4g.small`, about 20% cheaper) with arm64 images.
- Set CloudWatch log retention (for example 7 or 30 days) so logs stop accumulating forever.
- For learning, run the same manifests on kind or minikube locally for free, and use EKS only for the cloud-specific parts.

## Self-check and cheat sheet

Try answering each question before revealing it in your head; the answer follows the arrow.

1. Why copy `requirements.txt` before the rest of the code? -> So the dependency layer stays cached when only code changes.
2. What is the only thing CodeBuild and Kubernetes share? -> The image tag in ECR.
3. Why is the ECR repo immutable? -> A tag must always mean the same bytes, or rollback is unreliable.
4. Which identity runs `docker push` inside CodeBuild? -> The project's IAM service role, not your user.
5. What makes a push start a build? -> A CodeBuild webhook on the GitHub repo, created through a connection whose GitHub App can see that repo.
6. ClusterIP vs LoadBalancer? -> Internal-only virtual IP vs an internal IP plus a cloud load balancer with a public hostname.
7. How does a Service find its pods? -> Label `selector` matching pod labels.
8. Liveness vs readiness failure? -> Liveness restarts the container; readiness only stops sending it traffic.
9. Why does Postgres use `Recreate`? -> Two Postgres pods must never write the same data directory.
10. You changed a ConfigMap value; why does the app still see the old one? -> Env vars load at start; run `kubectl rollout restart`.
11. Is a Kubernetes Secret encrypted? -> No, base64 only; protect it with RBAC, etcd encryption and keeping it out of git.
12. How does kubectl authenticate to EKS? -> kubeconfig runs `aws eks get-token` with your AWS identity.
13. Where do container logs land in CloudWatch? -> `/aws/containerinsights/<cluster>/application`, one stream per container.
14. The pod has init containers you never declared. What happened? -> An admission webhook, here the CloudWatch add-on's OTel operator, injected them.
15. What costs money even with zero pods running? -> The EKS control plane, the nodes and the load balancer.

**Commands worth remembering**

```bash
# identity and auth
aws sso login --profile sswang
aws sts get-caller-identity
aws eks update-kubeconfig --name coworking-cluster --region us-east-1

# build side
aws codebuild list-builds-for-project --project-name coworking-build
aws ecr describe-images --repository-name coworking

# cluster state
kubectl get svc,pods,deploy
kubectl describe deployment coworking        # events, image, probes, injected annotations
kubectl describe svc postgresql-service      # endpoints = which pods it routes to
kubectl logs deploy/coworking --tail=20 -f

# release and rollback
scripts/03-deploy.sh 1.0.N
kubectl rollout status deploy/coworking
kubectl rollout undo deploy/coworking
kubectl rollout restart deploy/coworking     # reload ConfigMap/Secret env vars

# database access from your laptop
kubectl port-forward svc/postgresql-service 5432:5432

# local rehearsal and cleanup
kind create cluster --name cw-test && kind load docker-image coworking:local --name cw-test
scripts/99-teardown.sh
```
