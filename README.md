# Coworking Space Service: Analytics API on EKS

```
  git push main
       |
       v
 +-----------+  webhook  +-------------+  docker push    +--------------------+
 |  GitHub   | --------> |  CodeBuild  | --------------> |  ECR  "coworking"  |
 +-----------+           | buildspec   |  tag 1.0.<N>    |  immutable semver  |
                         +-------------+                 +--------------------+
                                                                   |
                          scripts/03-deploy.sh 1.0.<N>             | image pull
                                                                   v
 +------------------------------- EKS: coworking-cluster -------------------------------+
 |                                                                                        |
 |  Service coworking (LoadBalancer :5153) ---> Deployment coworking (Flask API)          |
 |                                                   |  env: ConfigMap + Secret            |
 |                                                   v                                     |
 |  Service postgresql-service (ClusterIP :5432) -> Deployment postgresql -> PV/PVC       |
 |                                                                                        |
 |  CloudWatch agent + Fluent Bit (add-on) -------> CloudWatch Container Insights         |
 +----------------------------------------------------------------------------------------+
```

## How it works

The analytics API is a Flask app in `analytics/` that serves reports from Postgres and logs a usage summary every 30 seconds, which doubles as a heartbeat in CloudWatch.
The `Dockerfile` packages it on `python:3.10-slim` with dependencies in a cached layer and runs it as a non-root user on port 5153.
Every push to `main` fires a CodeBuild webhook that runs `buildspec.yml`, building the image and pushing it to ECR.
Images are tagged `MAJOR.MINOR.BUILD`, where the patch number is CodeBuild's build counter, and the ECR repository is immutable so a tag always refers to the same image.
The manifests in `deployment/` define the API (Deployment plus LoadBalancer Service), Postgres (Deployment, ClusterIP Service, and a persistent volume), plaintext settings in a ConfigMap, and the database password in a separate Secret.
The cluster is declared in `infra/cluster.yaml` and created with eksctl, which also installs the CloudWatch Observability add-on that ships container logs to Container Insights.

## Releasing a change

Merge code to `main` and wait for the CodeBuild run to finish, since its log prints the new image tag.
Run `scripts/03-deploy.sh 1.0.N`, or omit the tag to take the newest image, and the script pins that tag in `deployment/coworking.yaml` and performs a rolling update.
Kubernetes shifts traffic to the new pod only after `/readiness_check` can query the database, so a broken build never replaces a healthy one.
Commit the updated manifest so the repository always records what is running, and roll back by re-running the script with the previous tag.
Bump `MAJOR_MINOR` in `buildspec.yml` for feature or breaking releases.
Configuration changes go in the ConfigMap or Secret followed by `kubectl rollout restart deploy/coworking`, because pods read environment variables only at startup.

## First-time setup and verification

Authenticate the AWS CLI, then run the numbered scripts in order, each of which is safe to re-run.
The webhook needs GitHub credentials connected once in the CodeBuild console.

```bash
scripts/01-bootstrap-ci.sh      # ECR repo, CodeBuild project, IAM role, webhook
scripts/02-create-cluster.sh    # EKS + Container Insights (~15 min)
scripts/03-deploy.sh            # Postgres, seed data, API
scripts/99-teardown.sh          # delete billable resources when done
```

`kubectl get svc coworking` shows the load balancer hostname, and `curl http://<host>:5153/api/reports/daily_usage` should return JSON.
Application logs are in the CloudWatch log group `/aws/containerinsights/coworking-cluster/application`.
Submission screenshots are in `screenshots/`.

## Stand-out suggestions

**Memory and CPU allocation.**
The API requests 100m CPU and 128Mi memory with a 256Mi memory limit, and Postgres requests 100m CPU and 256Mi with a 512Mi limit; measured idle usage is roughly 43Mi and 37Mi respectively.
CPU limits are deliberately omitted to avoid throttling during report bursts, while memory limits stop a leak from starving the node.

**Instance type.**
`t3.small` (2 vCPU, 2 GiB) fits best, because this I/O-bound API idles almost all the time and burstable CPU credits cover the occasional report query.
Two nodes leave headroom for the CloudWatch DaemonSets and a surge pod during rolling updates without paying for idle `m5` capacity.

**Saving costs.**
Tear the cluster down outside of use with `scripts/99-teardown.sh`, since the EKS control plane, nodes, and load balancer all bill hourly, and use Spot instances for non-production node groups.
Switching to Graviton `t4g.small` nodes with arm64 images cuts node cost by about 20%, and the ECR lifecycle policy already caps stored images at ten.
For production, a single ALB via the AWS Load Balancer Controller shared across services, plus right-sized CloudWatch log retention, avoids per-service load balancers and unbounded log storage.
