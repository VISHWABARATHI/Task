variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group"
}

variable "location" {
  type        = string
  description = "Azure region where the resources will be deployed"
}

/*
variable "storageAccountName" {
  type        = string
  description = "Name of the Azure Storage Account"
}
*/

variable "namespace" {
  type        = string
  description = "Namespace for the Kubernetes resources"
}



variable "container_registry_name" {
  type        = string
  description = "Name of the Azure Container Registry"
}



variable "cluster_name" {
  type        = string
  description = "Name of the AKS cluster"
}

/*
variable "kubernetes_version" {
  type        = string
  description = "Version of Kubernetes to deploy"
}
*/

variable "system_node_count" {
  type        = number
  description = "Number of nodes in the AKS cluster"
}

/*
variable "acr_name" {
  type        = string
  description = "Name of the Azure Container Registry"
}
*/

#Choose Nginx or Apache as webserver
variable "webserver_type" {
  description = "The type of webserver to deploy (nginx or apache)"
  type        = string
  #default     = "nginx"
  validation {
    condition     = contains(["nginx", "apache"], var.webserver_type)
    error_message = "webserver_type must be 'nginx' or 'apache'."
  }
}
