terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
    }
    helm = {
      source = "hashicorp/helm"
    }
    local = {
      source = "hashicorp/local"
    }
  }
  required_version = ">= 0.13"
}

variable "do_token" {
  type        = string
  description = "Your DigitalOcean API token. See https://cloud.digitalocean.com/account/api/tokens to generate a token."

  validation {
    condition     = can(regex("^\\w+$", var.do_token))
    error_message = "Your DigitalOcean API token must be a valid token."
  }
}

variable "group_number" {
  type        = string
  description = "The number of the bootcamp group."

  validation {
    condition     = can(regex("^[0-9A-Za-z_-]+$", var.group_number))
    error_message = "Enter a valid group number. Tip: it doesnt strictly need to be a number (e.g. you could create a group named 00-yourname), but it must only contain letters, numbers, underscores and dashes."
  }
}

variable "gremlin_team_id" {
  type        = string
  description = "The Gremlin team ID for the group. See https://app.gremlin.com/settings/teams to get your team ID."

  validation {
    condition     = can(regex("^[0-9A-Za-z_-]+$", var.gremlin_team_id))
    error_message = "Your Gremlin team ID must be a valid ID."
  }
}

variable "gremlin_team_secret" {
  type        = string
  description = "The Gremlin team secret for the group. See https://app.gremlin.com/settings/teams to get your team secret."

  validation {
    condition     = can(regex("^[0-9A-Za-z_-]+$", var.gremlin_team_secret))
    error_message = "Your Gremlin team secret must be a valid secret."
  }
}



# Set up the DO K8s cluster

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_kubernetes_cluster" "k8s_cluster" {
  name   = "group-${var.group_number}"
  region = "sfo2"
  # Grab the latest version slug from `doctl kubernetes options versions`
  version = "1.17.11-do.0"

  node_pool {
    name       = "group-${var.group_number}"
    size       = "s-1vcpu-2gb"
    node_count = 2
    auto_scale = true
    min_nodes  = 2
    max_nodes  = 3
    tags       = ["group-${var.group_number}"]

  }
}



resource "digitalocean_loadbalancer" "public" {
  name   = "group-${var.group_number}"
  region = "sfo2"

  forwarding_rule {
    entry_port      = 80
    entry_protocol  = "tcp"
    target_port     = 30001
    target_protocol = "tcp"
  }



  healthcheck {
    port     = 30001
    protocol = "tcp"
  }

  droplet_tag = "group-${var.group_number}"
}


resource "local_file" "k8s_config" {
  content  = digitalocean_kubernetes_cluster.k8s_cluster.kube_config[0].raw_config
  filename = pathexpand("~/.kube/group-${var.group_number}-config.yaml")
}

provider "helm" {
  kubernetes {
    load_config_file       = "false"
    host                   = digitalocean_kubernetes_cluster.k8s_cluster.endpoint
    token                  = digitalocean_kubernetes_cluster.k8s_cluster.kube_config[0].token
    cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.k8s_cluster.kube_config[0].cluster_ca_certificate)
  }
}

# Apply Boutique Shop Helm chart

resource "helm_release" "boutique" {
  name    = "boutique"
  chart   = "../extras/boutique"
  timeout = 600
}

# Apply Gremlin Helm chart

resource "helm_release" "gremlin_helm_chart" {
  name  = "gremlin"
  chart = "gremlin/gremlin"

  set {
    name  = "gremlin.secret.managed"
    value = "true"
  }
  set {
    name  = "gremlin.secret.type"
    value = "secret"
  }
  set {
    name  = "gremlin.secret.clusterID"
    value = "group-${var.group_number}"
  }
  set {
    name  = "gremlin.secret.teamID"
    value = var.gremlin_team_id
  }
  set {
    name  = "gremlin.secret.teamSecret"
    value = var.gremlin_team_secret
  }
}

output "do_lb" {
  value = digitalocean_loadbalancer.public.ip
}

