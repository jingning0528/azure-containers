include {
  path = find_in_parent_folders()
}

locals {
  app_env    = get_env("app_env")
  target_env = get_env("target_env")
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
  private_endpoints_subnet_name = "subnet-privateendpoints-dev"
  
  target_env = "dev"
EOF
}