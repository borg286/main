terraform {
  required_providers {
    helm       = { source  = "hashicorp/helm" }
    random     = { source  = "hashicorp/random" }
    kubernetes = { source  = "hashicorp/kubernetes" }
    local      = { source  = "hashicorp/local" } # Needed for local_file
    null       = { source  = "hashicorp/null" } # Needed for null_resource
  }
}

data "terraform_remote_state" "m1" {
  backend = "local"
  config = {
    path = "../m1-talos-bootstrap/terraform.tfstate"
  }
}

locals {
  node_ip            = data.terraform_remote_state.m1.outputs.node_ip
  cluster_name       = "talos-metal-single"
  cluster_endpoint   = "https://${local.node_ip}:6443"
  
  # URLs
  gitea_internal_url = "http://gitea-http.gitea.svc.cluster.local:3000"
  gitea_external_url = "http://${local.node_ip}:30080"
  admin_user         = "gitea_admin"
  privileged_labels = {
    "pod-security.kubernetes.io/enforce"         = "privileged"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/audit"           = "privileged"
    "pod-security.kubernetes.io/audit-version"   = "latest"
  }
}

resource "random_password" "gitea_admin" {
  length           = 24
  special          = true
  override_special = "!#$%"
}

# --- Provider Configuration ---

provider "kubernetes" {
  # This relies on the local_file resource in m1 being created first.
  config_path = data.terraform_remote_state.m1.outputs.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = data.terraform_remote_state.m1.outputs.kubeconfig_path
  }
}

# 1. Install Longhorn (Required for Persistent Volumes)

resource "kubernetes_namespace" "longhorn-system" {
  metadata {
    name = "longhorn-system"
    labels = local.privileged_labels
  }
}

resource "helm_release" "longhorn" {
  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = "1.7.2"
  namespace        = "longhorn-system"
  create_namespace = true
  values           = [ file("${path.module}/../../apps/longhorn.values.yaml") ]
}

# 2. Install Cert-Manager
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.1"
  namespace        = "cert-manager"
  create_namespace = true
  set = [{
    name  = "installCRDs"
    value = "true"
  }]
  values = [ file("${path.module}/../../apps/cert-manager.values.yaml") ]
}

# 3. Install Gitea (Requires Longhorn for PVC)
resource "kubernetes_namespace" "gitea" {
  metadata {
    name = "gitea"
  }
}

resource "kubernetes_secret" "gitea_admin" {
  depends_on = [kubernetes_namespace.gitea]
  metadata {
    name      = "gitea-admin-secret"
    namespace = kubernetes_namespace.gitea.metadata[0].name
  }
  type = "Opaque"
  data = {
    username = local.admin_user
    password = random_password.gitea_admin.result
  }
}


resource "helm_release" "gitea" {
  depends_on       = [helm_release.longhorn]
  name             = "gitea"
  repository       = "https://dl.gitea.com/charts/"
  chart            = "gitea"
  version          = "12.4.0"
  namespace        = "gitea"
  create_namespace = true
  values           = [ file("${path.module}/../../apps/gitea.values.yaml") ]
}


# --- Outputs for Milestone 3 ---
# Pass along the passwords for setting up the gitea resources
output "gitea_admin_pass" {
  value     = random_password.gitea_admin.result
  sensitive = true
}

output "gitea_password_fetch" {
  value = "Username: gitea_admin; kubectl get secret gitea-admin-secret --namespace=gitea --template='{{.data.password}}' | base64 -d"
  description = "Run this to print the gitea admin password (admin user is gitea_admin)"
}
