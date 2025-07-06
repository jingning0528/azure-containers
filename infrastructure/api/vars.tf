variable "app_name" {
  description = "Name of the application"
  type        = string
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

variable "container_apps_subnet_name" {
  description = "Name of the subnet for Container Apps"
  type        = string
}

variable "postgresql_server_fqdn" {
  description = "FQDN of the PostgreSQL server"
  type        = string
  default = "example.database.azure.com" # makes the terraform plan work without a real server
}

variable "postgresql_admin_username" {
  description = "PostgreSQL admin username"
  type        = string
  default = "pgadmin"
}

variable "postgresql_admin_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}

variable "database_name" {
  description = "Name of the database"
  type        = string
  default     = "app"
}

variable "api_image" {
  description = "The image for the API container"
  type        = string
}

variable "flyway_image" {
  description = "The image for the Flyway container"
  type        = string
}

variable "node_env" {
  description = "Node.js environment"
  type        = string
  default     = "production"
}

variable "min_replicas" {
  description = "Minimum number of replicas"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum number of replicas"
  type        = number
  default     = 3
}

variable "container_cpu" {
  description = "CPU allocation for containers"
  type        = number
  default     = 0.5
}

variable "container_memory" {
  description = "Memory allocation for containers"
  type        = string
  default     = "1Gi"
}

variable "create_container_registry" {
  description = "Whether to create an Azure Container Registry"
  type        = bool
  default     = false
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# APIM Variables
variable "web_subnet_name" {
  description = "Name of the web subnet for APIM deployment"
  type        = string
  default = "web-subnet"
}

variable "apim_publisher_name" {
  description = "APIM publisher name"
  type        = string
  default     = "API Publisher"
}

variable "apim_publisher_email" {
  description = "APIM publisher email"
  type        = string
}

variable "apim_sku_name" {
  description = "APIM SKU name (e.g., Developer_1, Standard_1)"
  type        = string
  default     = "Developer_1"
}

variable "apim_subscription_required" {
  description = "Whether APIM subscription is required for API access"
  type        = bool
  default     = false
}