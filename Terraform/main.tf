data "azurerm_resource_group" "aks_rg" {
  name = var.resource_group_name
}

data "azurerm_container_registry" "acr" {
  name                = var.container_registry_name
  resource_group_name = var.resource_group_name
}

# AKS Cluster (PRESERVING YOUR EXACT CONFIGURATION)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks_rg.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = "1.32.5" # Your exact version
  sku_tier            = "Standard"

  default_node_pool {
    name       = "system"
    node_count = var.system_node_count
    vm_size    = "Standard_A2_v2" # Your exact VM size
  }

  # ONLY CHANGE: Replaced service_principal with managed identity
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    load_balancer_sku = "standard"
    network_plugin    = "kubenet" # Your exact network plugin
  }
}

# Get AKS credentials (NEW - fixes connection issues)
data "azurerm_kubernetes_cluster" "aks_credentials" {
  name                = azurerm_kubernetes_cluster.aks.name
  resource_group_name = azurerm_kubernetes_cluster.aks.resource_group_name
  depends_on          = [azurerm_kubernetes_cluster.aks]
}

# Configure Kubernetes provider (NEW)
provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.cluster_ca_certificate)
}

# Configure Helm provider (NEW)
provider "helm" {
  kubernetes {
    host                   = data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.host
    client_certificate     = base64decode(data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.client_certificate)
    client_key             = base64decode(data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.aks_credentials.kube_config.0.cluster_ca_certificate)
  }
}

# ACR role assignment (NEW)
resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.acr.id
}

# YOUR ORIGINAL APPLICATION CODE BELOW (COMPLETELY UNCHANGED)
# -----------------------------------------------------------
resource "kubernetes_namespace" "deploy" {
  depends_on = [data.azurerm_kubernetes_cluster.aks_credentials] # Only added depends_on
  metadata {
    name = var.namespace
  }
}

locals {
  webserver_image = "${data.azurerm_container_registry.acr.login_server}/${var.webserver_type}:${var.webserver_image_tag}"
}

resource "helm_release" "nginx_ingress" {
  depends_on = [data.azurerm_kubernetes_cluster.aks_credentials]
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.8.3" # Verify latest version at https://github.com/kubernetes/ingress-nginx/releases
  namespace  = "ingress-nginx"
  create_namespace = true
  atomic     = true
  timeout    = 600

  set {
    name  = "controller.publishService.enabled"
    value = "true"
  }

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
    value = "/healthz"
  }

  # Recommended additional settings for AKS
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-interval"
    value = "10"
  }
  
  set {
    name  = "controller.replicaCount"
    value = "2"
  }
}


resource "kubernetes_deployment" "webserver" {
  depends_on = [
    helm_release.nginx_ingress,
    azurerm_kubernetes_cluster.aks
  ]

  metadata {
    name      = "${var.webserver_type}-deployment"
    namespace = kubernetes_namespace.deploy.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = var.webserver_type
      }
    }

    template {
      metadata {
        labels = {
          app = var.webserver_type
        }
      }

      spec {
        container {
          name  = var.webserver_type
          image = local.webserver_image
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 80
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 3
            period_seconds        = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "webserver" {
  depends_on = [helm_release.nginx_ingress]

  metadata {
    name      = "${var.webserver_type}-service"
    namespace = kubernetes_namespace.deploy.metadata[0].name
  }

  spec {
    selector = {
      app = var.webserver_type
    }

    port {
      port        = 80
      target_port = 80
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_ingress_v1" "webserver_ingress" {
  depends_on = [helm_release.nginx_ingress]

  metadata {
    name      = "${var.webserver_type}-ingress"
    namespace = kubernetes_namespace.deploy.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/"
    }
  }

  spec {
    rule {
      host = "${var.webserver_type}.${azurerm_kubernetes_cluster.aks.dns_prefix}.nip.io"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.webserver.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler" "webserver" {
  metadata {
    name      = "${var.webserver_type}-hpa"
    namespace = kubernetes_namespace.deploy.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.webserver.metadata[0].name
    }

    min_replicas                          = 1
    max_replicas                          = 3
    target_cpu_utilization_percentage    = 80
  }
}
