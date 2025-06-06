# Scale Out and Update a Containerized Application on a Kubernetes Cluster

Kubernetes makes each stage of a release—from building an image to proving it runs—declarative and script-friendly. This playbook stitches **all five challenge-lab tasks** into one README-ready guide. Each step includes the exact CLI commands, plus a brief explainer of the underlying GKE or Docker concept so teammates know _why_ as well as _how_.

---

## Prerequisites

Before you start, open **Cloud Shell** (Docker, kubectl, gsutil, and the Google CLI are pre-installed).

```bash
export PROJECT_ID=$(gcloud config get-value project)
export CLUSTER=echo-cluster
export ZONE=europe-west1-b
export ARCHIVE=echo-web-v2.tar.gz
```

_Cloud Shell already has application-default credentials for the active project_ ([cloud.google.com][1]).

---

## 1 · Build `echo-app:v2` from the source archive

### 1.1 Download the source bundle

```bash
gsutil cp gs://qwiklabs-gcp-00-58060b9598ee/$ARCHIVE .
```

`gsutil cp` pulls objects from Cloud Storage to local disk — handy for source, artifacts, or backups ([cloud.google.com][2], [cloud.google.com][3]).

### 1.2 Extract and build

```bash
tar -xzf $ARCHIVE && cd echo-web
docker build -t echo-app:v2 .
```

`docker build` sends the directory (the **build context**) to the Docker daemon, which runs the Dockerfile instructions to create an image layer stack ([cloud.google.com][4]).

### 1.3 Tag with a version

```bash
docker tag echo-app:v2 gcr.io/$PROJECT_ID/echo-app:v2
```

A registry prefix (`gcr.io/$PROJECT_ID`) tells Docker—and later Kubernetes—exactly where to store and pull the image ([cloud.google.com][4]).

---

## 2 · Push the image to **Container / Artifact Registry**

### 2.1 Authenticate Docker once

```bash
gcloud auth configure-docker gcr.io --quiet
```

This command inserts a `credHelper` into `~/.docker/config.json`, so Docker fetches short-lived OAuth tokens automatically ([cloud.google.com][5], [cloud.google.com][6]).

### 2.2 Push and verify

```bash
docker push gcr.io/$PROJECT_ID/echo-app:v2
gcloud container images list-tags gcr.io/$PROJECT_ID/echo-app
```

Pushing uploads any new layers; listing shows the digest and v2 tag, proving the image is stored in your project registry ([cloud.google.com][4], [stackoverflow.com][7]).

---

## 3 · Roll **echo-web** to v2 on the cluster

### 3.1 Point `kubectl` at the cluster

```bash
gcloud container clusters get-credentials $CLUSTER --zone $ZONE
```

This writes a **kubeconfig** context entry so `kubectl` securely talks to the correct control plane ([cloud.google.com][8], [cloud.google.com][1]).

### 3.2 Update the Deployment template

```bash
kubectl set image deployment/echo-web \
        echo-app=gcr.io/$PROJECT_ID/echo-app:v2
```

`kubectl set image` patches the Deployment; the Deployment controller starts a **rolling update** that swaps Pods without downtime ([kubernetes.io][9], [kubernetes.io][10]).

### 3.3 Watch the rollout

```bash
kubectl rollout status deployment/echo-web
```

The command waits until all new Pods are **Available**, an atomic checkpoint useful in CI/CD gates ([kubernetes.io][11], [komodor.com][12]).

### 3.4 Expose (or confirm) a public Service

If you created it earlier, simply check it:

```bash
kubectl get svc echo-web -o wide
```

Need one?

```bash
kubectl expose deployment echo-web --port 80 \
        --target-port 8000 --type LoadBalancer
```

A Service of type **LoadBalancer** asks GKE for a cloud load balancer with a stable external IP on port 80 that proxies to each Pod’s port 8000 ([cloud.google.com][13], [cloud.google.com][14]).

---

## 4 · Scale out to two replicas

```bash
kubectl scale deployment/echo-web --replicas=2
kubectl rollout status deployment/echo-web      # waits for 2/2 Ready
```

Changing `spec.replicas` makes the ReplicaSet create (or delete) Pods until the desired count is met — an example of Kubernetes’ reconciliation loop ([kubernetes.io][15], [komodor.com][16]).

---

## 5 · Prove the app is alive

```bash
EXTERNAL_IP=$(kubectl get svc echo-web \
              -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$EXTERNAL_IP/
```

Expect JSON similar to:

```json
{ "host": "echo-web-7cccfb4dcb-abcde", "version": "v2" }
```

Hit it several times to see hostnames alternate, confirming round-robin load-balancing across both Pods. The Service’s **Endpoints** object updates automatically whenever Pods become Ready, so traffic is only sent to healthy back-ends ([cloud.google.com][13], [cloud.google.com][4]).

---

## Clean-up & Next Steps

- **Rollback quickly** with `kubectl rollout undo deployment/echo-web` if v2 misbehaves ([komodor.com][12]).
- Add **readiness/liveness probes** to the Deployment for smarter health checks.
- Automate Steps 1-4 in Cloud Build or GitHub Actions so every git push → image push → rolling update.

With this playbook in your repo, anyone on the team can reproduce the full lifecycle: build, push, deploy, scale, and validate—complete with the Kubernetes concepts that make each command work.

[1]: https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl?utm_source=chatgpt.com "Install kubectl and configure cluster access - Google Cloud"
[2]: https://cloud.google.com/storage/docs/downloading-objects?utm_source=chatgpt.com "Download objects | Cloud Storage"
[3]: https://cloud.google.com/storage/docs/gsutil?utm_source=chatgpt.com "gsutil tool | Cloud Storage - Google Cloud"
[4]: https://cloud.google.com/artifact-registry/docs/docker/pushing-and-pulling?utm_source=chatgpt.com "Push and pull images | Artifact Registry documentation - Google Cloud"
[5]: https://cloud.google.com/sdk/gcloud/reference/auth/configure-docker?utm_source=chatgpt.com "gcloud auth configure-docker | Google Cloud CLI Documentation"
[6]: https://cloud.google.com/artifact-registry/docs/docker/authentication?utm_source=chatgpt.com "Configure authentication to Artifact Registry for Docker - Google Cloud"
[7]: https://stackoverflow.com/questions/44421300/pushing-an-image-to-google-container-registry-from-inside-a-docker-container?utm_source=chatgpt.com "Pushing an image to Google Container Registry from inside a ..."
[8]: https://cloud.google.com/sdk/gcloud/reference/container/clusters/get-credentials?utm_source=chatgpt.com "gcloud container clusters get-credentials"
[9]: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_set/kubectl_set_image/?utm_source=chatgpt.com "kubectl set image | Kubernetes"
[10]: https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/?utm_source=chatgpt.com "Performing a Rolling Update - Kubernetes"
[11]: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_status/?utm_source=chatgpt.com "kubectl rollout status - Kubernetes"
[12]: https://komodor.com/learn/kubectl-rollout-and-kubectl-rollout-restart-managing-kubernetes-deployments/?utm_source=chatgpt.com "Kubectl Rollout & Rollout Restart: Managing K8s Deployments"
[13]: https://cloud.google.com/kubernetes-engine/docs/concepts/service?utm_source=chatgpt.com "Understand Kubernetes Services | GKE networking - Google Cloud"
[14]: https://cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer-parameters?utm_source=chatgpt.com "LoadBalancer Service parameters | GKE networking - Google Cloud"
[15]: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_scale/?utm_source=chatgpt.com "kubectl scale | Kubernetes"
[16]: https://komodor.com/learn/kubectl-scale-deployment-the-basics-and-a-quick-tutorial/?utm_source=chatgpt.com "How to Scale Kubernetes Pods with Kubectl Scale Deployment"
