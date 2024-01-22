terraform {
  backend "s3" {
    bucket         = "cardano-playground-terraform"
    dynamodb_table = "terraform"
    key            = "terraform"
    region         = "eu-central-1"
  }

  required_providers {
    grafana = {
      source = "grafana/grafana"
    }
    mimir = {
      source = "fgouteroux/mimir"
    }
  }
}

variable "deadmanssnitch_api_url" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "grafana_token" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "grafana_url" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_alertmanager_alertmanager_uri" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_alertmanager_ruler_uri" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_alertmanager_username" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_api_key" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_prometheus_alertmanager_uri" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_prometheus_ruler_uri" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "mimir_prometheus_username" {
  nullable  = false
  sensitive = true
  type      = string
}

variable "pagerduty_api_key" {
  nullable  = false
  sensitive = true
  type      = string
}

provider "grafana" {
  alias = "playground"
  auth  = var.grafana_token
  url   = var.grafana_url
}

provider "mimir" {
  alertmanager_uri = var.mimir_prometheus_alertmanager_uri
  alias            = "prometheus"
  org_id           = "1"
  password         = var.mimir_api_key
  ruler_uri        = var.mimir_prometheus_ruler_uri
  username         = var.mimir_prometheus_username
}

provider "mimir" {
  alertmanager_uri = var.mimir_alertmanager_alertmanager_uri
  alias            = "alertmanager"
  org_id           = "1"
  password         = var.mimir_api_key
  ruler_uri        = var.mimir_alertmanager_ruler_uri
  username         = var.mimir_alertmanager_username
}

resource "grafana_contact_point" "pagerduty" {
  name     = "pagerduty"
  provider = "grafana.playground"
  pagerduty = {
    integration_key = var.pagerduty_api_key
  }
}

resource "grafana_dashboard" "node_exporter_cpu_and_system" {
  provider    = "grafana.playground"
  config_json = "..."
}

resource "grafana_notification_policy" "policy" {
  contact_point = grafana_contact_point.pagerduty.name
  provider      = "grafana.playground"
  group_by = [
    "..."
  ]
}

resource "mimir_alertmanager_config" "pagerduty" {
  provider = "mimir.alertmanager"

  receiver {
    name = "pagerduty"
    pagerduty_configs = {
      service_key = var.pagerduty_api_key
    }
  }

  receiver {
    name = "deadmanssnitch"
    webhook_configs = {
      send_resolved = false
      url           = var.deadmanssnitch_api_url
    }
  }

  route {
    group_interval  = "5m"
    group_wait      = "30s"
    receiver        = "pagerduty"
    repeat_interval = "1y"

    child_route {
      group_interval  = "5m"
      group_wait      = "30s"
      receiver        = "deadmanssnitch"
      repeat_interval = "5m"
      matchers = [
        "alertname=\"DeadMansSnitch\""
      ]
    }

    group_by = [
      "..."
    ]
  }
}

resource "mimir_rule_group_alerting" "deadmanssnitch" {
  name      = "deadmanssnitch"
  namespace = "deadmanssnitch"
  provider  = "mimir.prometheus"

  rule {
    alert = "DeadMansSnitch"
    expr  = "vector(1)"
    annotations = {
      description = "This is a DeadMansSnitch meant to ensure that the entire alerting pipeline is functional, see: [deadmanssnitch](https://deadmanssnitch.com).\nThis alert should ALWAYS be in alerting state. This enables Deadman's Snitch to report when this monitoring server dies or can otherwise no longer alert."
      summary     = "DeadMansSnitch Pipeline"
    }
    labels = {
      severity = "info"
    }
  }
}

resource "mimir_rule_group_alerting" "nginx_vts" {
  name      = "nginx-vts"
  namespace = "nginx"
  provider  = "mimir.prometheus"

  rule {
    alert = "http_high_internal_error_rate"
    expr  = "rate(nginx_vts_server_requests_total{code=\"5xx\"}[5m]) * 50 > on(instance, host) rate(nginx_vts_server_requests_total{code=\"2xx\"}[5m])"
    for   = "15m"
    annotations = {
      description = "{{$labels.instance}}  number of correctly served requests is less than 50 times the number of requests aborted due to an internal server error"
      summary     = "{{$labels.instance}}: High http internal error (code 5xx) rate"
    }
    labels = {
      severity = "page"
    }
  }
}
