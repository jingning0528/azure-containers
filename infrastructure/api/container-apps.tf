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

# Data source for database Key Vault (can be in same or different RG)
data "azurerm_key_vault" "database" {
  name                = var.database_key_vault_name
  resource_group_name = var.resource_group_name  # Same RG as database is now in the same RG
}

# Container Apps Environment with VNet integration
resource "azurerm_container_app_environment" "main" {
  name                           = "${var.app_name}-containerapp-env-${var.app_env}"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  infrastructure_subnet_id       = data.azurerm_subnet.container_apps.id
  internal_load_balancer_enabled = true

  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }
}

# Log Analytics Workspace for Container Apps
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.app_name}-logs-${var.app_env}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }
}

# User Assigned Managed Identity for Container Apps
resource "azurerm_user_assigned_identity" "container_apps" {
  name                = "${var.app_name}-containerapp-identity-${var.app_env}"
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }
}

# Grant access to Key Vault secrets
resource "azurerm_role_assignment" "key_vault_secrets_user" {
  scope                = data.azurerm_key_vault.database.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

# Container Registry (if using private registry) - Landing Zone compliant
resource "azurerm_container_registry" "main" {
  count               = var.create_container_registry ? 1 : 0
  name                = "${replace(var.app_name, "-", "")}acr${var.app_env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium"
  admin_enabled       = false

  # Azure Landing Zone security requirements
  public_network_access_enabled = false

  # Note: Network rule set configuration would require Premium SKU
  # For now, keeping it simple for Standard SKU compatibility

  tags = {
    managed-by = "terraform"
    environment = var.app_env
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
  name                         = "${var.app_name}-api-${var.app_env}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
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
        value = "3001"
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
        port      = 3001
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/api/health"
        port      = 3001
      }
    }
  }

  secret {
    name  = "postgres-host"
    value = var.postgresql_server_fqdn
  }

  secret {
    name                = "postgres-user"
    key_vault_secret_id = "${data.azurerm_key_vault.database.vault_uri}secrets/${var.postgresql_admin_username_secret_name}"
    identity            = azurerm_user_assigned_identity.container_apps.id
  }

  secret {
    name                = "postgres-password"
    key_vault_secret_id = "${data.azurerm_key_vault.database.vault_uri}secrets/${var.postgresql_admin_password_secret_name}"
    identity            = azurerm_user_assigned_identity.container_apps.id
  }

  secret {
    name  = "postgres-database"
    value = var.database_name
  }

  ingress {
    allow_insecure_connections = false
    external_enabled          = false
    target_port               = 3001

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }

  depends_on = [azurerm_role_assignment.key_vault_secrets_user]
}

# Container App Job for Database Migrations
resource "azurerm_container_app_job" "migrations" {
  name                         = "${var.app_name}-migrations-${var.app_env}"
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
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
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "FLYWAY_URL"
        value = "jdbc:postgresql://${var.postgresql_server_fqdn}:5432/${var.database_name}?sslmode=require"
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
    name                = "postgres-user"
    key_vault_secret_id = "${data.azurerm_key_vault.database.vault_uri}secrets/${var.postgresql_admin_username_secret_name}"
    identity            = azurerm_user_assigned_identity.container_apps.id
  }

  secret {
    name                = "postgres-password"
    key_vault_secret_id = "${data.azurerm_key_vault.database.vault_uri}secrets/${var.postgresql_admin_password_secret_name}"
    identity            = azurerm_user_assigned_identity.container_apps.id
  }

  tags = {
    managed-by = "terraform"
    environment = var.app_env
  }

  depends_on = [azurerm_role_assignment.key_vault_secrets_user]
}
