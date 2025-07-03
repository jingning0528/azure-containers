variable "app_name" {
  description = "Name of the application"
  type        = string
  validation {
    condition     = lower(var.app_name) == var.app_name
    error_message = "The app_name must be in lowercase."
  }
}

variable "app_env" {
  description = "Application environment (dev, test, prod)"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "Canada Central"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "vnet_name" {
  description = "Name of the existing virtual network"
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Resource group name where the virtual network exists"
  type        = string
}

variable "private_endpoints_subnet_name" {
  description = "Name of the subnet for private endpoints"
  type        = string
}

variable "container_app_fqdn" {
  description = "FQDN of the Container App API"
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
}

variable "centralized_dns_resource_group_name" {
  description = "Resource group name where centralized private DNS zones are managed in Azure Landing Zone"
  type        = string
  default     = "rg-dns-central"
}