# Monitoring Cluster

In this, we'll try to document the purpose and process of setting up a
monitoring cluster.

We hope that it'll be helpful for people who desire autonomy, predictable and
low costs, and complete control over their assets.

The stack consists of:

- Grafana for dashboards
- Mimir for metrics storage
- Prometheus for metrics collection and the blackbox exporter
- Caddy for authentication of endpoints and reverse proxying

The cluster is not intended to be highly available, so only a single server
will serve each environment.

The metrics are stored in S3, and the machine is disposable, so in cases of
failure we'll have a way to get most of our history restored.

## Grafana

Grafana is a powerful dashboarding tool that allows you to create beautiful
dashboards with a variety of data sources.

## Mimir

## Prometheus


