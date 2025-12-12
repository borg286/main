terraform {
  required_providers {
    talos      = { source  = "siderolabs/talos" }
    local      = { source  = "hashicorp/local" } # Needed for local_file
    null       = { source  = "hashicorp/null" } # Needed for null_resource
  }
}

variable "node_ip" {
  type        = string
  description = "The IP address of the single-node cluster."
}
variable "disk_device" {
  type        = string
  default     = "/dev/nvme0n1"
  description = "The disk device for Talos installation."
}

variable "longhorn_space" {
  type        = string
  default     = "460GB"
  description = "How much space on the above disk to give longhorn."
}
variable "talos_version" {
  type        = string
  default     = "v1.11.5"
  description = "Which version of talos to use."
}

variable "github_url" {
  type        = string
  default     = "https://github.com/borg286/main.git"
  description = "The github URL you wish to initially mirror into your cluster."
}

variable "gitea_hostname" {
  type        = string
  description = "The hostname for the Gitea instance."
}

locals {
  cluster_name       = "talos-metal-single"
  cluster_endpoint   = "https://${var.node_ip}:6443"
  
  admin_user         = "gitea_admin"
}

# --- Providers and Random Passwords (Needed across all steps) ---

provider "talos" {}

# --- Talos Configuration & Bootstrap ---

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

resource "local_file" "talos_client_config" {
  filename = "${path.module}/../.tmp/talosconfig"
  # talos_machine_secrets.this.client_configuration holds the raw YAML config
  content  = templatefile("${path.module}/talosconfig.tmpl",
    {
      context_name = "mynode"
      client_configuration = talos_machine_secrets.this.client_configuration
    }
  )
  file_permission = "0600" # Ensure it's secure
}

data "talos_machine_configuration" "single_node" {
  cluster_name     = local.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

resource "talos_machine_configuration_apply" "this" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.single_node.machine_configuration
  node                        = var.node_ip
  endpoint                    = var.node_ip
  config_patches = [
    # This config includes setting up longhorn partition
    # But also creates a gitea operator, the gitea server, an org, and repo which mirrors github_url
    # Some dependencies aren't as simple as pointing to some yaml online, but must be rendered by
    # a fancy system (argo, helm, kustomize...) and most have a helm route. We can't use the standard
    # helm_release because it relies on k8s being up at plan time. But it seems happy if we restrict
    # ourselves to helm_template. We then feed that into our machine-config and rely on the standard
    # reconsiliation loop to spin it up.
    templatefile("${path.module}/machine-config.yaml.tmpl", {
      disk_device       = var.disk_device
      longhorn_space    = var.longhorn_space
      talos_version     = var.talos_version
    }),

  ]
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.node_ip
}

# --- Local Kubeconfig File Write ---

resource "local_file" "kubeconfig" {
  filename = "${path.module}/kubeconfig"
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
}

#resource "local_file" "gitea_manifest" {
#  filename = "${path.module}/generated-gitea.yaml"
#  content  = templatefile("${path.module}/gitea.yaml.tmpl", {
#    github_url=var.github_url,
#    gitea_hostname=var.gitea_hostname
#  })
#}

#resource "null_resource" "post_kubeconfig" {
#  depends_on = [local_file.kubeconfig, local_file.gitea_manifest, local_file.gitea_postgres_manifest]
#  triggers = {post_install_hash = sha256(local.post_install_command)}
#  provisioner "local-exec" {
#    command = local.post_install_command
#  }
#}


# --- Outputs for Milestone 2/3 ---

output "kubeconfig_path" {
  # Output the absolute path for m2 to use
  value = abspath(local_file.kubeconfig.filename)
}

output "node_ip" {
  value = var.node_ip
}

output "talosconfig_path" {
  value = abspath(local_file.talos_client_config.filename)
}

output "kubectl_export" {
  value = "export KUBECONFIG=${abspath(local_file.kubeconfig.filename)}"
  description = "Run this to access the cluster"
}

output "talosconfig_export" {
  value = "export TALOSCONFIG=${abspath(local_file.talos_client_config.filename)}"
  description = "Run this to open the Talos dashboard"
}


output "talosctl_dashboard" {
  value = "talosctl -n=${var.node_ip} -e=${var.node_ip} dashboard"
  description = "Run this to open the Talos dashboard"
}
