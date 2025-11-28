terraform {
  required_providers {
    gitea      = { source  = "go-gitea/gitea" }
    helm       = { source  = "hashicorp/helm" }
    random     = { source  = "hashicorp/random" }    
    local      = { source  = "hashicorp/local" }
    null       = { source  = "hashicorp/null" }
  }
}

# --- Remote State Data Source ---

data "terraform_remote_state" "m2" {
  backend = "local"
  config = {
    path = "../m2-k8s-apps/terraform.tfstate"
  }
}
data "terraform_remote_state" "m1" {
  backend = "local"
  config = {
    path = "../m1-talos-bootstrap/terraform.tfstate"
  }
}


# --- Local Values from Remote State ---

locals {
  admin_user    = "gitea_admin"
  admin_pass    = data.terraform_remote_state.m2.outputs.gitea_admin_pass
  target_node_ip = data.terraform_remote_state.m1.outputs.node_ip
  repo_name = "main"  
  # Redefine external URL using the fetched IP
  # TODO: switch to some FQDN once we get cloudflare DNS routing figured out and reliable
  gitea_external_url = "http://${local.target_node_ip}:30000"
  gitea_internal_url = "http://gitea-http.gitea.svc.cluster.local:3000"
  git_push_command = <<EOT
      set -e
      TEMP_DIR="/tmp/git-temp-sync"

      # Navigate to the root project (not terraform root which is 2 folders down).
      cd ../..
      SOURCE_PATH="$(pwd)"

      REPO_URL="http://${local.admin_user}:${local.admin_pass}@${local.target_node_ip}:30000/${gitea_org.main_org.name}/${gitea_repository.config_repo.name}.git"
      
      # 1. CLEAN UP: Safely delete the old temporary directory
      rm -rf $TEMP_DIR

      # 2. CLONE: Get the latest state of the repository
      git clone --depth 1 $REPO_URL $TEMP_DIR

      # 3. WIPE: Clear existing files (except .git) to handle deletions in the source
      cd $TEMP_DIR
      find . -maxdepth 1 -not -name '.git' -not -name '.' -exec rm -rf {} +

      # --- A. Copy Top-Level Files (e.g., README.md) ---
      # Finds files at maxdepth 1 (root) excluding hidden and state files.

      (cd "$SOURCE_PATH" && \
        find . -maxdepth 1 -type f \
          -not -name '.*' \
          -not -name 'terraform.tfstate*' \
          -print0 | cpio -0pdum $TEMP_DIR/
      )
      # --- B. Copy the 'apps' Directory Contents Recursively ---
      # Starts search inside apps/ to ensure path is clean, excludes hidden and state files.
      (cd "$SOURCE_PATH" && 
        find ./apps -not -path '*/.*' \
          -not -name 'terraform.tfstate*' \
          -print0 | cpio -0pdum $TEMP_DIR/
      )
      # --- C. Copy the 'terraform_bootstrap' Directory Contents Recursively ---
      # Starts search inside terraform_bootstrap/, excluding hidden and state files.
      (cd "$SOURCE_PATH" && 
        find ./terraform_bootstrap -not -path '*/.*' \
          -not -name 'terraform.tfstate*' \
          -print0 | cpio -0pdum $TEMP_DIR/
      )
      # 5. COMMIT & PUSH
      cd $TEMP_DIR
      git config user.email "terraform@local"
      git config user.name "Terraform Bootstrap"
      git add .

      # Idempotency check: only commit and push if changes exist
      if git diff --staged --quiet; then
        echo "No changes to commit. Skipping push."
      else
        git commit -m "Update from Terraform: $(date)"
        git push origin master
        echo "Configuration pushed to Gitea."
      fi

      cd ..
      rm -rf $TEMP_DIR
    EOT

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


provider "gitea" {
  base_url = local.gitea_external_url
  username = local.admin_user
  password = local.admin_pass # Use the fetched admin password
  # TODO: go back to secure once we get TLS sorted out with cert-manager.
  insecure = true
}

# --- Gitea Resources ---

resource "gitea_org" "main_org" {
  name        = "main_org"
  visibility  = "private"
}

resource "gitea_team" "main_team" {
  name         = "main_team"
  organisation = gitea_org.main_org.name
  description  = "The main team"
  permission   = "write"
}

resource "gitea_repository" "config_repo" {
  username       = gitea_org.main_org.name
  name           = local.repo_name
  description    = "ArgoCD Cluster Configuration"
  private        = true
  auto_init      = true
  default_branch = "master"
}

# --- Git Sync & Push (Idempotent) ---
resource "null_resource" "git_push" {
  depends_on = [gitea_repository.config_repo]
  triggers = {
    # 1. HASH OF FILE CONTENTS: This ensures it runs if any tracked file changes.
    source_hash = sha1(join("", [
      for f in flatten([
        fileset(path.module, "../../apps/**/*"), 
      ]) : filesha1(f)
    ]))
    
    # 2. HASH OF RESOURCE DEFINITION: This ensures it runs if the provisioner command changes.
    # We explicitly hash the 'command' attribute of the provisioner.
    provisioner_hash = sha1(local.git_push_command)
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = local.git_push_command
  }
}

# Push terraform now that we have a repo to point to
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_secret" "argocd_repo" {
  depends_on = [kubernetes_namespace.argocd]
  metadata {
    name      = "gitea-repo"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  data = {
    url      = "${local.gitea_internal_url}/${gitea_org.main_org.name}/${gitea_repository.config_repo.name}.git"
    username = local.admin_user
    password = local.admin_pass
    type     = "git"
  }
  type = "Opaque"
}

resource "helm_release" "argocd" {
  # We use the inline manifest for the Root App, but we install the ArgoCD server here.
  depends_on       = [kubernetes_secret.argocd_repo]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.6.12"
  namespace        = "argocd"
  create_namespace = true
  values           = [ file("${path.module}/../../apps/argocd.values.yaml") ]
}


# Our bootstrap App-of-apps. This points to the same apps/ folder
# where we have a kustomize.yaml that globs all the other apps.
resource "kubernetes_manifest" "argocd_root_app" {
  depends_on = [
    helm_release.argocd,
  ]
  manifest = yamldecode(file("${path.module}/../../apps/root-app.yaml"))
}


# --- Final Outputs ---

output "gitea_ui" {
  value = local.gitea_external_url
}

output "argocd_password_fetch" {
  value = "Username: admin; kubectl get secret argocd-initial-admin-secret --namespace=argocd --template='{{.data.password}}' | base64 -d"
  description = "Run this to print the argocd admin password (admin user is admin)"
}

output "argocd_ui" {
  value = "https://${local.target_node_ip}:30081"
}
