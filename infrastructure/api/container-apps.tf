# Azure Container Apps for API backend

data "azurerm_client_config" "current" {}

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Data source for existing subnet for Container Apps
data "azurerm_subnet" "container_apps" {
  name                 = var.container_apps_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Resource group for API resources
resource "azurerm_resource_group" "api" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Container Apps Environment v2 with workload profiles and VNet integration
resource "azurerm_container_app_environment" "main" {
  name                           = "${var.app_name}-containerapp"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.api.name
  infrastructure_subnet_id       = data.azurerm_subnet.container_apps.id
  internal_load_balancer_enabled = true

  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  # Workload profiles for v2 Container Apps Environment
  # This allows /27 subnet size instead of /23 required by consumption plan
  workload_profile {
    maximum_count = var.max_replicas
    minimum_count = var.min_replicas
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Log Analytics Workspace for Container Apps
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.app_name}-logs"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# User Assigned Managed Identity for Container Apps
resource "azurerm_user_assigned_identity" "container_apps" {
  name                = "${var.app_name}-containerapp-identity"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name

  tags = var.common_tags
}

# Container Registry (if using private registry) - Landing Zone compliant
resource "azurerm_container_registry" "main" {
  count               = var.create_container_registry ? 1 : 0
  name                = "${replace(var.app_name, "-", "")}acr"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location
  sku                 = "Premium"
  admin_enabled       = false

  # Azure Landing Zone security requirements
  public_network_access_enabled = false
  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Grant Container Apps environment access to Container Registry
resource "azurerm_role_assignment" "acr_pull" {
  count                = var.create_container_registry ? 1 : 0
  scope                = azurerm_container_registry.main[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

# Container App for API Backend
resource "azurerm_container_app" "api" {
  name                         = "${var.app_name}-api"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.api.name
  revision_mode               = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "api"
      image  = var.api_image
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name  = "NODE_ENV"
        value = var.node_env
      }

      env {
        name  = "PORT"
        value = "3000"
      }

      env {
        name        = "POSTGRES_HOST"
        secret_name = "postgres-host"
      }

      env {
        name        = "POSTGRES_USER"
        secret_name = "postgres-user"
      }

      env {
        name        = "POSTGRES_PASSWORD"
        secret_name = "postgres-password"
      }

      env {
        name        = "POSTGRES_DATABASE"
        secret_name = "postgres-database"
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/api/health"
        port      = 3000
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/api/health"
        port      = 3000
      }
    }
  }

  secret {
    name  = "postgres-host"
    value = var.postgresql_server_fqdn
  }

  secret {
    name  = "postgres-user"
    value = var.postgresql_admin_username
  }

  secret {
    name  = "postgres-password"
    value = var.postgresql_admin_password
  }

  secret {
    name  = "postgres-database"
    value = var.database_name
  }

  ingress {
    allow_insecure_connections = false
    external_enabled          = false
    target_port               = 3000

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Container App Job for Database Migrations
resource "azurerm_container_app_job" "migrations" {
  name                         = "${var.app_name}-migrations"
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.api.name
  replica_timeout_in_seconds   = 1800

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  # Manual trigger configuration for GitHub Actions deployment
  manual_trigger_config {
    parallelism            = 1
    replica_completion_count = 1
  }


  template {
    container {
      name   = "migrations"
      image  = var.flyway_image
      cpu    = 1
      memory = "2Gi"

      env {
        name  = "FLYWAY_URL"
        value = "jdbc:postgresql://${var.postgresql_server_fqdn}:5432/${var.database_name}"
      }

      env {
        name        = "FLYWAY_USER"
        secret_name = "postgres-user"
      }

      env {
        name        = "FLYWAY_PASSWORD"
        secret_name = "postgres-password"
      }

      env {
        name  = "FLYWAY_BASELINE_ON_MIGRATE"
        value = "true"
      }

      env {
        name  = "FLYWAY_DEFAULT_SCHEMA"
        value = "app"
      }
    }
  }

  secret {
    name  = "postgres-user"
    value = var.postgresql_admin_username
  }

  secret {
    name  = "postgres-password"
    value = var.postgresql_admin_password
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Automatic execution of migrations job on terraform apply
resource "null_resource" "run_migrations" {
  depends_on = [azurerm_container_app_job.migrations]

  triggers = {
    # Run whenever the job configuration changes
    job_id = azurerm_container_app_job.migrations.id
    # Run on every terraform apply
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = "az containerapp job start --name ${azurerm_container_app_job.migrations.name} --resource-group ${azurerm_resource_group.api.name}"
  }
}
