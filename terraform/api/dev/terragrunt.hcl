include {
  path = find_in_parent_folders()
}

locals {
  app_env      = get_env("app_env")
  flyway_image = get_env("flyway_image")
  api_image    = get_env("api_image")
  target_env   = get_env("target_env")
}

# Include the common terragrunt configuration for all modules
generate "dev_tfvars" {
  path              = "dev.auto.tfvars"
  if_exists         = "overwrite"
  disable_signature = true  
  contents          = <<-EOF
  location = "Canada Central"
  
  # VNet configuration (existing Landing Zone resources)
  vnet_name = "vnet-landingzone-dev"
  vnet_resource_group_name = "rg-networking-dev"
  container_apps_subnet_name = "subnet-containerapps-dev"
  
  # Container configuration
  min_replicas = 1
  max_replicas = 3
  container_cpu = 0.5
  container_memory = "1Gi"
  node_env = "development"
  create_container_registry = false
  
  target_env = "dev"
  app_env = "${local.app_env}"
EOF
}