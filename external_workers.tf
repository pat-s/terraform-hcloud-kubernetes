# First-class support for out-of-band (non-hcloud) Talos worker nodes.
#
# Motivation: nodes provisioned outside this module (bare-metal, another cloud,
# a VM on a Hetzner dedicated server, etc.) can join the cluster over KubeSpan,
# but rendering their machine config by hand is error-prone - it is easy to omit
# cluster-level settings the module normally injects (service subnet -> kubelet
# clusterDNS, kubelet server-cert rotation, discovery, certSANs, sysctls), which
# breaks pod DNS and metrics-server in non-obvious ways.
#
# This renders each external worker's config from the SAME cluster-level base the
# managed workers get, minus the hcloud-specific pieces (eth0/eth1 link config,
# nodeIP pinned to the hcloud node CIDR, cloud-provider=external, hcloud system
# volume). The result is exposed as an output; the operator applies it with
# `talosctl apply-config`. No hcloud_server is created.
#
# See also: external node IPs are added to the `talosctl health` node list in
# talos.tf so `synchronize_manifests` does not hang on "unexpected nodes".

variable "external_worker_nodepools" {
  type = map(object({
    # The node's in-cluster InternalIP (e.g. its KubeSpan-reachable address).
    # Added to the health-check node list so the health gate tolerates it.
    # Optional: omit if you also run with cluster_healthcheck_enabled = false.
    node_ipv4 = optional(string)
    # Per-node Talos config patches: install disk/image, the node's own
    # network (kubelet.nodeIP.validSubnets, KubeSpan filters), an optional
    # static hostname, labels, etc. Merged on top of the cluster-level base.
    config_patches = optional(any, [])
  }))
  default     = {}
  description = "Out-of-band (non-hcloud) Talos workers to render join configs for. Keyed by node name."
}

variable "external_workers_disable_ccm_node_lifecycle" {
  type        = bool
  default     = true
  description = "When external_worker_nodepools is set, disable the hcloud CCM cloud-node-lifecycle controller so it does not delete the non-hcloud nodes (which it treats as \"does not exist in the cloud provider\"). Cluster-wide side effect: dead hcloud nodes are then not auto-reaped. Set false only if you keep external nodes off that controller another way."
}

locals {
  external_workers_enabled = length(var.external_worker_nodepools) > 0

  # CCM: the default controller set runs cloud-node-lifecycle, which deletes any
  # node missing from the hcloud API - including external nodes. The Talos CCM
  # owns node lifecycle here, so disable it when external nodes exist. Merged into
  # the CCM chart values in hcloud.tf. Opt-out via the variable above.
  external_workers_ccm_helm_values = (local.external_workers_enabled && var.external_workers_disable_ccm_node_lifecycle) ? {
    args = { controllers = "*,-cloud-node-lifecycle" }
  } : {}

  # CSI node DaemonSet: the chart's default affinity only excludes robot/root
  # servers (NotIn ...), which a label-less external node satisfies, so the driver
  # schedules there and crashloops (it cannot attach hcloud volumes). Require a
  # real cloud node. Merged into the CSI chart values in hcloud.tf.
  external_workers_csi_helm_values = local.external_workers_enabled ? {
    node = {
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [
                { key = "instance.hetzner.cloud/is-root-server", operator = "NotIn", values = ["true"] },
                { key = "instance.hetzner.cloud/provided-by", operator = "NotIn", values = ["robot"] },
                { key = "instance.hetzner.cloud/provided-by", operator = "In", values = ["cloud"] },
              ]
            }]
          }
        }
      }
    }
  } : {}
}

locals {
  # The cluster-level worker base for external nodes: the same settings a managed
  # worker gets, WITHOUT the hcloud-specific link/nodeIP/cloud-provider/volume
  # patches. This is what makes an external node inherit clusterDNS (from
  # serviceSubnets), kubelet server-cert rotation, discovery, certSANs, proxy and
  # sysctls - the settings most commonly missed when hand-rolling the config.
  talos_external_worker_base_config_patches = concat(
    [{
      machine = {
        install = {
          image           = local.talos_installer_image_url
          extraKernelArgs = var.talos_extra_kernel_args
        }
        certSANs = local.talos_certificate_san
        kubelet = merge(
          {
            # NB: no cloud-provider=external here. An hcloud node relies on a CCM
            # to initialize it; an external node is not in any cloud API, so it
            # self-initializes (no uninitialized taint to clear). Keep
            # rotate-server-certificates so metrics-server can scrape it.
            extraArgs = merge(
              {
                "rotate-server-certificates" = true
              },
              var.kubernetes_kubelet_extra_args
            )
            extraConfig = {
              shutdownGracePeriod             = "90s"
              shutdownGracePeriodCriticalPods = "15s"
            }
          },
          var.kubernetes_kubelet_image != null ? {
            image = "${var.kubernetes_kubelet_image}:${var.kubernetes_version}"
          } : {}
        )
        kernel = {
          modules = var.talos_kernel_modules
        }
        sysctls = merge(
          {
            "net.core.somaxconn"                 = "65535"
            "net.core.netdev_max_backlog"        = "4096"
            "net.ipv6.conf.default.disable_ipv6" = "${var.talos_ipv6_enabled ? 0 : 1}"
            "net.ipv6.conf.all.disable_ipv6"     = "${var.talos_ipv6_enabled ? 0 : 1}"
          },
          var.talos_sysctls_extra_args
        )
        registries = var.talos_registries
        features = {
          hostDNS = local.talos_host_dns
        }
        logging = {
          destinations = var.talos_logging_destinations
        }
      }
      cluster = {
        network = {
          dnsDomain      = var.cluster_domain
          podSubnets     = [local.network_pod_ipv4_cidr]
          serviceSubnets = [local.network_service_ipv4_cidr]
          cni            = { name = "none" }
        }
        proxy = merge(
          {
            disabled = var.cilium_kube_proxy_replacement_enabled
          },
          var.kubernetes_proxy_image != null ? {
            image = "${var.kubernetes_proxy_image}:${var.kubernetes_version}"
          } : {}
        )
        discovery = local.talos_discovery
      }
    }],
    [local.talos_resolver_config_patch],
    [local.talos_time_sync_config_patch],
    local.talos_static_host_config_patches,
    local.talos_trusted_certs_config_patches
  )
}

data "talos_machine_configuration" "external_worker" {
  for_each = var.external_worker_nodepools

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_external
  kubernetes_version = var.kubernetes_version
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    [for patch in local.talos_external_worker_base_config_patches : yamlencode(patch)],
    [for patch in each.value.config_patches : yamlencode(patch)],
    [for patch in var.worker_config_patches : yamlencode(patch)]
  )
}

output "talos_machine_configurations_external_worker" {
  description = "Rendered Talos worker machine configs for out-of-band nodes, keyed by node name. Apply with `talosctl apply-config`."
  value       = { for name, cfg in data.talos_machine_configuration.external_worker : name => cfg.machine_configuration }
  sensitive   = true
}
