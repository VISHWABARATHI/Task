data "azurerm_resource_group" "aks_rg" {
  name = var.resource_group_name
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks_rg.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = "1.32.5"
  sku_tier            = "Standard"

  default_node_pool {
    name       = "system"
    node_count = var.system_node_count
    vm_size    = "standard_a2_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    load_balancer_sku = "standard"
    network_plugin    = "kubenet"
  }
}

data "azurerm_container_registry" "acr" {
  name                = var.container_registry_name
  resource_group_name = var.resource_group_name
}

# This is sufficient for ACR pull access - no need for admin credentials or secrets
resource "azurerm_role_assignment" "role_acrpull" {
  depends_on = [azurerm_kubernetes_cluster.aks]
  scope                            = data.azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

locals {
  webserver_image = "${data.azurerm_container_registry.acr.login_server}/${var.webserver_type}:${var.webserver_image_tag}"
}

resource "kubernetes_namespace" "deploy" {
  depends_on = [azurerm_kubernetes_cluster.aks]
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_deployment" "webserver" {
  depends_on = [
    helm_release.nginx_ingress,
    azurerm_kubernetes_cluster.aks,
    azurerm_role_assignment.role_acrpull
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
        # No imagePullSecrets needed when using managed identity
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

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  }
}

resource "helm_release" "nginx_ingress" {
  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_role_assignment.role_acrpull
  ]
  
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.8.3"
  namespace  = "kube-system"

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
    min_replicas = 1
    max_replicas = 3
    target_cpu_utilization_percentage = 80
  }
}