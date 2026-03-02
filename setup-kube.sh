#!/bin/bash

if [ "$1" == "--clean" ]; then
    echo "--- Starting Deep Clean ---"

    # 1. Delete the main applications first
    # We use build | delete to ensure Helm-generated resources are identified
    echo "Stopping applications and observability stack..."
    # kustomize build k8s/ --enable-helm | kubectl delete -f - --ignore-not-found --timeout=60s
    kubectl delete -k k8s/

    # 2. Specifically target the "Heavyweights"
    # Helm deployments like Prometheus and Loki often have webhooks that block deletion
    echo "Cleaning up CRDs and Webhooks..."
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/ --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagerconfigs.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagers.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-podmonitors.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-probes.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheusagents.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheuses.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheusrules.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-scrapeconfigs.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-servicemonitors.yaml --ignore-not-found
    # kubectl delete -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-thanosrulers.yaml --ignore-not-found

    kubectl delete mutatingwebhookconfigurations.admissionregistration.k8s.io -l app.kubernetes.io/instance=prometheus --ignore-not-found
    kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io -l app.kubernetes.io/instance=prometheus --ignore-not-found
    kubectl delete validatingwebhookconfiguration prometheus-kube-stack-admission --ignore-not-found
    
    # 3. Handle Databases and Persistent Volumes
    echo "Patching and removing Persistent Volumes..."
    SERVICES=("user" "post" "comment")
    for SERVICE in "${SERVICES[@]}"; do
        # Remove the claimRef so the PV can be deleted/reused
        kubectl patch -f k8s/databases/${SERVICE}_db/${SERVICE}-db-pv.yaml -p '{"spec":{"claimRef":null}}' 2>/dev/null
        # Force delete the PVCs if they are stuck
        kubectl delete pvc -l app=${SERVICE}-db -n default --ignore-not-found --grace-period=0 --force
    done

    # 4. ArgoCD Cleanup
    echo "Removing ArgoCD..."
    # kubectl delete -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found

    # 5. Namespace wiping
    # We delete namespaces last to ensure all resources inside are gone
    echo "Wiping namespaces..."
    # kubectl delete namespace observability argocd --ignore-not-found --timeout=30s
    echo "--- Clean complete ---"
    exit 0
fi

# kubectl apply -f k8s/namespaces.yaml

# Check if Metrics Server is installed, if not, install it
if ! kubectl get deployment metrics-server -n kube-system > /dev/null 2>&1; then
    echo "--- Installing Metrics Server ---"
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # Patch for Docker Desktop (usually needs insecure-tls to work locally)
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
else
    echo "--- Metrics Server already installed, skipping ---"
fi

# 2. Check/Install NGINX Ingress Controller (For localhost routing)
if ! kubectl get namespace ingress-nginx > /dev/null 2>&1; then
    echo "--- Installing NGINX Ingress Controller for Kind ---"
    
    # Kind-specific manifest that includes patches for local port mapping
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

    echo "Waiting for Ingress Controller to be ready (this can take a minute)..."
    
    # Wait for the controller pod to be ready
    kubectl wait --namespace ingress-nginx \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=120s
else
    echo "--- Ingress Controller: OK ---"
fi

if [ "$1" == "--local" ]; then
    # 3. Build the API image locally
    echo "--- Building Docker Image ---"
    # docker build -t user-api:local ./user-api
    # docker build -t post-api:local ./post-api
    docker build -t comment-api:local ./comment-api
    # docker build -t auth-api:local ./auth-api

fi

# 3.5 Check/Install Sealed Secrets Controller
if ! kubectl get deployment -n kube-system sealed-secrets-controller > /dev/null 2>&1; then
    echo "--- Installing Sealed Secrets Controller ---"

    # Get the latest release version and apply the manifest
    # This installs the controller into the 'kube-system' namespace by default
    LATEST_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4)
    
    kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${LATEST_VERSION}/controller.yaml"

    echo "Waiting for Sealed Secrets Controller to be ready..."

    # Wait for the controller to be fully operational
    kubectl wait --namespace kube-system \
      --for=condition=available deployment/sealed-secrets-controller \
      --timeout=120s
else
    echo "--- Sealed Secrets Controller: OK ---"
fi


# 3. Check/Install ArgoCD
if ! kubectl get namespace argocd > /dev/null 2>&1; then

    kubectl create namespace argocd

    echo "--- Installing ArgoCD ---"
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side

    echo "--- Patching ArgoCD for Ingress (Insecure Mode) ---"
    kubectl patch deployment argocd-server -n argocd \
      --type json \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'

    kubectl wait --namespace argocd \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/name=argocd-server \
      --timeout=180s

    # 5. Retrieve Initial Admin Password
    ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    echo "--------------------------------------------------------"
    echo "ArgoCD Installation Complete!"
    echo "URL: https://localhost (If using Ingress) or use port-forward"
    echo "Username: admin"
    echo "Password: $ARGOCD_PASS"
    echo "--------------------------------------------------------"
    # Save password to a local file so you don't lose it
    echo "$ARGOCD_PASS" > k8s/argocd/.argocd-password
else
    echo "--- ArgoCD: OK ---"
fi

# # 4. Create Secrets from your .env file
# echo "--- Syncing Secrets from .env ---"

kubectl create secret generic "user-api-secrets" --from-env-file="./User-API/.env" --dry-run=client -o yaml | \
kubeseal --format yaml > k8s/secrets/user-api-sealed.yaml

kubectl create secret generic "post-api-secrets" --from-env-file="./Post-API/.env" --dry-run=client -o yaml | \
kubeseal --format yaml > k8s/secrets/post-api-sealed.yaml

kubectl create secret generic "comment-api-secrets" --from-env-file="./Comment-API/.env" --dry-run=client -o yaml | \
kubeseal --format yaml > k8s/secrets/comment-api-sealed.yaml

kubectl create secret generic "auth-api-secrets" --from-env-file="./Auth-API/.env" --dry-run=client -o yaml | \
kubeseal --format yaml > k8s/secrets/auth-api-sealed.yaml

# 5. Apply Kubernetes Manifests
echo "--- Deploying to Kubernetes ---"
# Run this to install all required Prometheus Operator CRDs directly

# Monitoring Coreos CRDs
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagerconfigs.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagers.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-podmonitors.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-probes.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheusagents.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheuses.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheusrules.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-scrapeconfigs.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-servicemonitors.yaml
# kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-thanosrulers.yaml


# You must have the 'kustomize' standalone binary installed for this
# This renders the Helm charts FIRST, then applies the result to K8s
# kustomize build k8s/ --enable-helm | kubectl apply -f -
kubectl apply -k k8s/
echo "--- Deployment Complete ---"
echo "Check status with: kubectl get pods"
echo "Watch scaling with: kubectl get hpa -w"