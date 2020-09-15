terraform {
  experiments = [variable_validation]
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
variable "datadog_apikey" {
  type        = string
  description = "The Datadog API Key. See https://app.datadoghq.com/account/settings#api to get or create an API Key."

  validation {
    condition     = can(regex("^\\w+$", var.datadog_apikey))
    error_message = "Your Datadog API key must be a valid API Key."
  }
}
data "digitalocean_domain" "default" {
  name = "gremlinbootcamp.com"
}

variable "datadog_appkey" {
  type        = string
  description = "The Datadog Application Key. See https://app.datadoghq.com/account/settings#api to get or create an Application Key."

  validation {
    condition     = can(regex("^\\w+$", var.datadog_appkey))
    error_message = "Your Datadog Application Key must be a valid Application Key."
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

resource "digitalocean_certificate" "cert" {
  name    = "cert-${var.group_number}"
  type    = "lets_encrypt"
  domains = ["group${var.group_number}.gremlinbootcamp.com"]

  lifecycle {
    create_before_destroy = true
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
    certificate_id  = digitalocean_certificate.cert.id
  }

  forwarding_rule {
    entry_port      = 443
    entry_protocol  = "https"
    target_port     = 30001
    target_protocol = "http"
    certificate_id  = digitalocean_certificate.cert.id
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

# Apply Datadog Helm chart

resource "helm_release" "datadog_helm" {
  name       = "datadog"
  repository = "https://kubernetes-charts.storage.googleapis.com"
  chart      = "datadog"

  values = [
    "${file("../extras/datadog-values.yaml")}"
  ]

  set {
    name  = "datadog.apiKey"
    value = var.datadog_apikey
  }

  set {
    name  = "datadog.tags"
    value = "{group:${var.group_number}, cluster:group-${var.group_number}}"
  }
}

provider "datadog" {
  api_key = var.datadog_apikey
  app_key = var.datadog_appkey
}

resource "datadog_dashboard" "dashboard" {
  title       = "Group ${var.group_number} Dashboard"
  description = "Automatically created using the terraform provider. Changes will be lost."
  layout_type = "ordered"

  widget {
    group_definition {
      layout_type = "ordered"
      title       = "System Metrics"

      widget {
        check_status_definition {
          title    = "Active Nodes"
          check    = "datadog.agent.up"
          grouping = "cluster"
          tags     = ["group:${var.group_number}"]
        }
      }

      widget {
        hostmap_definition {
          title = "Nodes by CPU"
          request {
            fill {
              q = "max:system.cpu.system{group:${var.group_number}} by {host}"
            }
          }
          no_metric_hosts = false
          no_group_hosts  = true
          scope           = ["group:${var.group_number}"]
          style {
            palette      = "green_to_orange"
            palette_flip = false
            fill_min     = "3"
            fill_max     = "100"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "CPU Usage"
          request {
            q            = "avg:system.cpu.user{group:${var.group_number}} by {host}"
            display_type = "line"
            style {
              palette    = "purple"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          marker {
            display_type = "error dashed"
            value        = "y = 0"
          }
          show_legend = false
        }
      }

      widget {
        timeseries_definition {
          title = "Memory Used"
          request {
            q            = "avg:system.mem.used{group:${var.group_number}} by {host}"
            display_type = "line"
            style {
              palette    = "dog_classic"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }
      widget {
        timeseries_definition {
          title = "System IO"
          request {
            q            = "avg:system.io.util{group:${var.group_number}} by {host}"
            display_type = "line"
            style {
              palette    = "dog_classic"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      widget {
        timeseries_definition {
          title = "Disk Used"
          request {
            q            = "avg:system.disk.used{group:${var.group_number}} by {host}"
            display_type = "line"
            style {
              palette    = "cool"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      widget {
        timeseries_definition {
          title = "Network Bytes"
          request {
            q            = "avg:system.net.bytes_sent{group:${var.group_number}} by {host}"
            display_type = "line"
            style {
              palette    = "dog_classic"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          request {
            q            = "avg:system.net.bytes_rcvd{group:${var.group_number}} by {host}"
            display_type = "line"
            style {
              palette    = "dog_classic"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }
    }
  }

  # Service Metrics
  widget {
    group_definition {
      layout_type = "ordered"
      title       = "Service Metrics"

      widget {
        timeseries_definition {
          title = "TCP Response Time per Service"
          request {
            q            = "avg:network.tcp.response_time{group:${var.group_number}} by {url}"
            display_type = "line"
            style {
              palette    = "dog_classic"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      # adservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:adservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "adservice Response Time"
        }
      }
      # cartservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:cartservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "cartservice Response Time"
        }
      }
      # checkoutservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:checkoutservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "checkoutservice Response Time"
        }
      }
      # currencyservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:currencyservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "currencyservice Response Time"
        }
      }
      # emailservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:emailservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "emailservice Response Time"
        }
      }
      # frontend
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:frontend}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "frontend Response Time"
        }
      }
      # paymentservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:paymentservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "paymentservice Response Time"
        }
      }
      # productcatalogservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:productcatalogservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "productcatalogservice Response Time"
        }
      }
      # recommendationservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:recommendationservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "recommendationservice Response Time"
        }
      }
      # shippingservice
      widget {
        query_value_definition {
          request {
            q          = "avg:network.tcp.response_time{group:${var.group_number},instance:shippingservice}*1000"
            aggregator = "last"
          }
          autoscale   = false
          custom_unit = "ms"
          precision   = "3"
          text_align  = "center"
          title       = "shippingservice Response Time"
        }
      }
    }
  }


  widget {
    group_definition {
      layout_type = "ordered"
      title       = "Kubernetes Metrics"

      widget {
        query_value_definition {
          title = "Running containers"
          request {
            q          = "sum:docker.containers.running{group:${var.group_number}}"
            aggregator = "avg"
            conditional_formats {
              comparator = ">"
              value      = 0
              palette    = "green_on_white"
            }
          }
          autoscale  = true
          precision  = 0
          text_align = "center"
        }
      }

      widget {
        query_value_definition {
          title = "Stopped containers"
          request {
            q          = "sum:docker.containers.stopped{group:${var.group_number}}"
            aggregator = "avg"
            conditional_formats {
              comparator = ">"
              value      = 0
              palette    = "yellow_on_white"
            }
          }
          autoscale  = true
          precision  = 0
          text_align = "center"
        }
      }

      widget {
        toplist_definition {
          title = "Pods per Node"
          request {
            q = "top(sum:kubernetes.pods.running{group:${var.group_number}} by {host}, 5, 'last', 'desc')"
          }
        }
      }

      widget {
        hostmap_definition {
          title = "Kubernetes Pods/Containers per Node"
          request {
            fill {
              q = "avg:process.stat.container.cpu.total_pct{group:${var.group_number}} by {host}"
            }
          }
          node_type       = "container"
          no_metric_hosts = true
          no_group_hosts  = true
          group           = ["host"]
          scope           = ["group:${var.group_number}"]
          style {
            palette      = "green_to_orange"
            palette_flip = false
          }
        }
      }

      widget {
        hostmap_definition {
          title = "CPU % Grouped by Microservices"
          request {
            fill {
              q = "avg:process.stat.container.cpu.total_pct{group:${var.group_number}} by {host}"
            }
          }
          node_type       = "container"
          no_metric_hosts = false
          no_group_hosts  = false
          group           = ["kube_deployment"]
          scope           = ["group:${var.group_number}"]
          style {
            palette      = "YlOrRd"
            palette_flip = false
            fill_min     = "0"
            fill_max     = "100"
          }
        }
      }

      widget {
        toplist_definition {
          title = "Most CPU-intensive pods"
          request {
            q = "top(sum:kubernetes.cpu.usage.total{group:${var.group_number}} by {pod_name}, 100, 'mean', 'desc')"
          }
        }
      }

      widget {
        toplist_definition {
          title = "Most memory-intensive pods"
          request {
            q = "top(sum:kubernetes.memory.usage{group:${var.group_number}} by {pod_name}, 50, 'mean', 'desc')"
          }
        }
      }

      widget {
        note_definition {
          content          = "Additional information & resources:\n\n- [Kubernetes Dashboard](https://app.datadoghq.com/screen/integration/86/kubernetes---overview?tpl_var_scope=group%3A${var.group_number})\n- [Containers Dashboard](https://app.datadoghq.com/containers?tags=group%3A${var.group_number})\n- [Logs](https://app.datadoghq.com/logs?query=group%3A${var.group_number})"
          background_color = "white"
          font_size        = "18"
          text_align       = "left"
          show_tick        = false
          tick_pos         = "50%"
          tick_edge        = "left"
        }
      }
    }
  }

  widget {
    group_definition {
      layout_type = "ordered"
      title       = "Redis Metrics"

      widget {
        query_value_definition {
          title = "Blocked clients"
          request {
            q          = "sum:redis.clients.blocked{group:${var.group_number}}"
            aggregator = "max"
            conditional_formats {
              comparator = ">"
              value      = 1
              palette    = "white_on_red"
            }
            conditional_formats {
              comparator = "<"
              value      = 1
              palette    = "white_on_green"
            }
          }
          autoscale  = true
          precision  = 0
          text_align = "center"
        }
      }

      widget {
        query_value_definition {
          title = "Redis keyspace"
          request {
            q          = "sum:redis.keys{group:${var.group_number}}"
            aggregator = "max"
            conditional_formats {
              comparator = ">"
              value      = 0
              palette    = "white_on_green"
            }
          }
          autoscale  = true
          precision  = 2
          text_align = "left"
        }
      }

      widget {
        timeseries_definition {
          title = "Commands per second"
          request {
            q            = "sum:redis.net.commands{group:${var.group_number}}"
            display_type = "line"
            style {
              palette    = "grey"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      widget {
        timeseries_definition {
          title = "Connected clients"
          request {
            q            = "sum:redis.net.clients{group:${var.group_number}}"
            display_type = "line"
            style {
              palette    = "cool"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      widget {
        timeseries_definition {
          title = "Cache hit rate"
          request {
            q            = "(avg:redis.stats.keyspace_hits{group:${var.group_number}}/(avg:redis.stats.keyspace_hits{group:${var.group_number}}+avg:redis.stats.keyspace_misses{group:${var.group_number}}))*100"
            display_type = "line"
            style {
              palette    = "dog_classic"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      widget {
        timeseries_definition {
          title = "Latency"
          request {
            q            = "avg:redis.info.latency_ms{group:${var.group_number}}"
            display_type = "line"
            style {
              palette    = "orange"
              line_type  = "solid"
              line_width = "normal"
            }
          }
          yaxis {
            scale        = "linear"
            min          = "auto"
            max          = "auto"
            include_zero = true
          }
          event {
            q = "gremlin.team:group_${var.group_number}"
          }
          show_legend = false
        }
      }

      widget {
        note_definition {
          content          = "For more Redis information, see the [Redis Dashboard](https://app.datadoghq.com/screen/integration/15/redis---overview?tpl_var_scope=group%3A${var.group_number})"
          background_color = "white"
          font_size        = "18"
          text_align       = "left"
          show_tick        = false
          tick_pos         = "50%"
          tick_edge        = "left"
        }
      }
    }
  }
  widget {
    group_definition {
      layout_type = "ordered"
      title       = "Information for Bootcamp 201"
      widget {
        note_definition {
          content          = "# To use Status Checks with Synthetic Monitor: \n **Endpoint URL:** `v1/synthetics/tests/${datadog_synthetics_test.synthetics_browser_test_https.id}/results` \n \n  ** DD-API-KEY: ** `235ff852e09fe521b8dd76fdb64c17ef` \n \n ** DD-APPLICATION-KEY:** `4590f02cf44334405a2418f243c743569024567d`  \n\n **Monitor:** https://app.datadoghq.com/synthetics/details/${datadog_synthetics_test.synthetics_browser_test_https.id}?live=1h"
          background_color = "white"
          font_size        = "18"
          text_align       = "left"
          show_tick        = false
          tick_pos         = "50%"
          tick_edge        = "left"
        }
      }
      widget {
        note_definition {
          content          = "# To use the SDK and Demo environment:\n **First, Login:** \n Open: [Repl.it](https://repl.it/)\n\n ** Username: **  `community+group${var.group_number}@gremlin.com` \n\n** Password:**  `ChaosCertified01!`\n\n"
          background_color = "white"
          font_size        = "18"
          text_align       = "left"
          show_tick        = false
          tick_pos         = "50%"
          tick_edge        = "left"
        }
      }
      widget {
        note_definition {
          content          = "# To use the SDK and Demo environment (cont) \n **Access your code:** \n Open: https://repl.it/@gremlin${var.group_number}/Gremlin-Python-SDK#main.py"
          background_color = "white"
          font_size        = "18"
          text_align       = "left"
          show_tick        = false
          tick_pos         = "50%"
          tick_edge        = "left"
        }
      }
    }
  }

}

resource "datadog_synthetics_test" "synthetics_browser_test_https" {
  type = "browser"
  request = {
    method = "GET"
    url    = "https://group${var.group_number}.gremlinbootcamp.com/"
  }
  locations = ["aws:us-west-1"]
  options = {
    tick_every = 900
  }
  name       = "Group ${var.group_number} Test for Bootcamp (HTTPS)"
  message    = "Checks that website loads over https, no steps"
  tags       = ["bootcamp", "https"]
  device_ids = ["laptop_large"]
  status     = "live"
}

resource "datadog_synthetics_test" "synthetics_browser_test_http" {
  type = "browser"
  request = {
    method = "GET"
    url    = "http://group${var.group_number}.gremlinbootcamp.com/"
  }
  locations = ["aws:us-west-1"]
  options = {
    tick_every = 900
  }
  name       = "Group ${var.group_number} Test for Bootcamp (HTTP)"
  message    = "Checks that website loads over http, no steps"
  tags       = ["bootcamp", "http"]
  device_ids = ["laptop_large"]
  status     = "live"
}

# Apply Boutique Shop Helm chart

resource "helm_release" "boutique" {
  name    = "boutique"
  chart   = "../extras/boutique"
  timeout = 600
}



resource "digitalocean_record" "default" {

  domain = data.digitalocean_domain.default.name
  type   = "A"
  name   = "group${var.group_number}"
  # this creates the subdomain, but it's still the wrong IP
  # TODO: try: kubernetes_service.frontend_external.load_balancer_ingress.0.ip
  value = "${digitalocean_loadbalancer.public.ip}"
}

output "dd_syn_check_id" {
  value = datadog_synthetics_test.synthetics_browser_test_https.id
}

output "do_lb" {
 value = digitalocean_loadbalancer.public.ip
}
