include {
  path = find_in_parent_folders()
}

locals {
  app_env = get_env("app_env")
}

# Include the common terragrunt configuration for all modules
generate "dev_tfvars" {
  path              = "dev.auto.tfvars"
  if_exists         = "overwrite"
  disable_signature = true  
  contents          = <<-EOF
  resource_group_name = "rg-quickstart-containers-dev"
  location = "Canada Central"
  
  # VNet configuration (existing Landing Zone resources)
  vnet_name = "vnet-landingzone-dev"
  vnet_resource_group_name = "rg-networking-dev"
  database_subnet_name = "subnet-database-dev"
  
  # Azure Landing Zone centralized DNS
  centralized_dns_resource_group_name = "rg-dns-central"
  
  # PostgreSQL configuration
  postgresql_sku_name = "GP_Standard_D2s_v3"
  postgresql_storage_mb = 32768
  backup_retention_period = 1
  ha_enabled = false
  geo_redundant_backup_enabled = false
  
  target_env = "dev"
EOF
}