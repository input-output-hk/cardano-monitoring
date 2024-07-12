# OpenTofu

To update dashboards and alerts in a declarative way, we use [OpenTofu](https://opentofu.org/).

Here's an example in HCL to specify PagerDuty, some alerts, and a dashboard
(omitted the JSON for it).

## Variables

There are several required variables for specifying the Grafana and Mimir
providers, as well as the pagerduty key and DeadMansSnitch ping URL.

Here's an example tfvars file to provide these:

```
deadmanssnitch_api_url              = "https://nosnch.in/xxxxxxxxxx"
grafana_token                       = "xxx"
grafana_url                         = "https://example.com"
mimir_alertmanager_alertmanager_uri = "https://example.com/mimir"
mimir_alertmanager_ruler_uri        = "https://example.com/mimir/prometheus"
mimir_alertmanager_username         = "bob"
mimir_api_key                       = "xxx"
mimir_prometheus_alertmanager_uri   = "https://example.com/mimir/alertmanager"
mimir_prometheus_ruler_uri          = "https://example.com/mimir/prometheus"
mimir_prometheus_username           = "bob"
pagerduty_api_key                   = "xxx"
```

### Code

```hcl
{{#include grafana.tf}}
``` 
