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


variable "postgresql_admin_username" {
  description = "Administrator username for PostgreSQL server"
  type        = string
  default     = "pgadmin"
}

variable "postgresql_sku_name" {
  description = "SKU name for PostgreSQL Flexible Server"
  type        = string
  default     = "B1ms" # Basic SKU for development purposes
}

variable "postgresql_storage_mb" {
  description = "Storage in MB for PostgreSQL server"
  type        = number
  default     = 5000
}

variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backup"
  type        = bool
  default     = false
}

variable "ha_enabled" {
  description = "Enable high availability"
  type        = bool
  default     = false
}

variable "standby_availability_zone" {
  description = "Availability zone for standby replica"
  type        = string
  default     = "2"
}

variable "auto_grow_enabled" {
  description = "Enable auto-grow for storage"
  type        = bool
  default     = true
}

variable "database_name" {
  description = "Name of the database to create"
  type        = string
  default     = "app"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
}
variable "db_master_password" {
  description = "Master password for the PostgreSQL server"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.db_master_password) >= 12
    error_message = "The db_master_password must be at least 12 characters long."
  }
}
variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}