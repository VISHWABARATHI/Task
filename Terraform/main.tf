data "azurerm_resource_group" "aks_rg" {
  name = var.resource_group_name
}


/*
resource "azurerm_resource_group" "aks_rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "Storage" {
  name                     = var.storageAccountName
  resource_group_name      = azurerm_resource_group.aks_rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS" 
}

resource "azurerm_storage_container" "example" {
  name                  = "tfstate"
  storage_account_name  = azurerm_storage_account.Storage.name
  container_access_type = "private"
}
*/


/*
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.aks_rg.name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = false
}
*/


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
    vm_size    = "Standard_D2alds_v6"
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

resource "azurerm_role_assignment" "role_acrpull" {
  depends_on = [azurerm_kubernetes_cluster.aks]
  scope                            = data.azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
  }




# Deploying the webserver image to AKS
locals {
  webserver_image = var.webserver_type == "nginx" ? "${data.azurerm_container_registry.acr.login_server}/nginx:latest" : "${data.azurerm_container_registry.acr.login_server}/apache:latest"
}


#Create a namespace for deployment
resource "kubernetes_namespace" "deploy" {
  depends_on = [azurerm_kubernetes_cluster.aks]
  metadata {
    name = var.namespace
  }
}

# Pull the webserver image from ACR
resource "kubernetes_deployment" "webserver" {
  depends_on = [helm_release.nginx_ingress, azurerm_kubernetes_cluster.aks]
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
          port {
            container_port = 80
          }
        }
      }
    }
  }
}

/*
#Ingress resource to expose the webserver
resource "kubernetes_ingress" "webserver_ingress" {
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
      # host = "${var.webserver_type}.${azurerm_kubernetes_cluster.aks.dns_prefix}.nip.io"
      http {
        path {
          path = "/"
          backend {
            service_name = kubernetes_service.webserver.metadata[0].name
            service_port = 80
          }
        }
      }
    }
  }
}
*/

#Service
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


#kubernetes
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
}

#Helm
provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  }
}

resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "kube-system"

  set{
      name  = "controller.publishService.enabled"
      value = "true"
    }
  
}
