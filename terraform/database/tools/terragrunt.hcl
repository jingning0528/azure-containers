include {
  path = find_in_parent_folders()
}

locals {
  app_env = get_env("app_env")
}

# Include the common terragrunt configuration for all modules
generate "tools_tfvars" {
  path              = "tools.auto.tfvars"
  if_exists         = "overwrite"
  disable_signature = true  
  contents          = <<-EOF
  resource_group_name = "rg-quickstart-containers-tools"
  location = "Canada Central"
  target_env = "tools"
EOF
}

