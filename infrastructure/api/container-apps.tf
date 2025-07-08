# Azure Container Apps for API backend

data "azurerm_client_config" "current" {}

# Data source for existing virtual network
data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}
data "azurerm_subnet" "private_endpoint" {
  name                 = var.private_endpoint_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Data source for existing subnet for Container Apps
data "azurerm_subnet" "container_apps" {
  name                 = var.container_apps_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.vnet_resource_group_name
}

# Data source for existing web subnet for APIM
data "azurerm_subnet" "web" {
  name                 = var.web_subnet_name
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
  infrastructure_resource_group_name = "ME_${var.app_name}-containerapp"
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

# Application Insights for enhanced monitoring and logging
resource "azurerm_application_insights" "main" {
  name                = "${var.app_name}-appinsights"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  application_type    = "other"
  workspace_id        = azurerm_log_analytics_workspace.main.id
  
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

  # Add explicit dependency to ensure proper order
  depends_on = [
    azurerm_container_app_environment.main,
    azurerm_log_analytics_workspace.main
  ]
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }
  
  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas
    init_container {
      name   = "${var.app_name}-migrations"
      image  = var.flyway_image
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name  = "FLYWAY_URL"
        value = "jdbc:postgresql://${var.postgresql_server_fqdn}/${var.database_name}?sslmode=require"
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
      env {
        name  = "FLYWAY_CONNECT_RETRIES"
        value = "30"
      }
      env {
        name  = "FLYWAY_GROUP"
        value = "true"
      }
      env {
        name  = "FLYWAY_LOG_LEVEL"
        value = "DEBUG"
      }

      # Add Application Insights connection for enhanced logging
      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.main.connection_string
      }
    }
    container {
      name   = "${var.app_name}-api"
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

      # Add Application Insights for enhanced logging and monitoring
      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.main.connection_string
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

    # Conditionally add PostgreSQL client sidecar container
    dynamic "container" {
      for_each = var.enable_psql_sidecar ? [1] : []
      content {
        name   = "${var.app_name}-psql-client"
        image  = "ghcr.io/bcgov/nr-containers/alpine:3.22"
        cpu    = "0.25"
        memory = "0.5Gi"
        command = ["/bin/sh"]
        args    = ["-c", "echo 'PostgreSQL sidecar started. Keeping container alive...'; while true; do sleep 360000; done"]

        env {
          name  = "APP_NAME"
          value = var.app_name
        }

        # Add database connection environment variables
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

# Public IP for Application Gateway
resource "azurerm_public_ip" "app_gateway" {
  name                = "qaca-api-tools-gw"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# WAF Policy for Application Gateway
resource "azurerm_web_application_firewall_policy" "main" {
  name                = "${var.app_name}-waf-policy"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location

  policy_settings {
    enabled                     = true
    mode                       = "Prevention"
    request_body_check         = true
    file_upload_limit_in_mb    = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
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

# Key Vault for storing SSL certificates
resource "azurerm_key_vault" "app_gateway" {
  name                = "${replace(var.app_name, "-", "")}appgwkv"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Landing Zone compliance - restrict public access via network ACLs
  # Use private endpoint only for Key Vault access
  public_network_access_enabled = false
  
  # Enable for template deployment to allow Application Gateway access
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = true

  # Policy compliance - deletion protection settings
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  # Policy compliance - use Azure RBAC instead of access policies
  enable_rbac_authorization = true

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Private endpoint for Key Vault (placed in private endpoint subnet for management access)
resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.app_name}-kv-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.api.name
  subnet_id           = data.azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${var.app_name}-kv-psc"
    private_connection_resource_id = azurerm_key_vault.app_gateway.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags
    ]
  }
}

# Grant Application Gateway managed identity access to Key Vault using RBAC
resource "azurerm_role_assignment" "key_vault_secrets_user" {
  scope                = azurerm_key_vault.app_gateway.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

resource "azurerm_role_assignment" "key_vault_certificate_user" {
  scope                = azurerm_key_vault.app_gateway.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = azurerm_user_assigned_identity.container_apps.principal_id
}

# Azure managed certificate (requires domain validation)
resource "azurerm_key_vault_certificate" "app_gateway" {
  name         = "${var.app_name}-ssl-cert"
  key_vault_id = azurerm_key_vault.app_gateway.id

  certificate_policy {
    issuer_parameters {
      # Policy compliance - use integrated certificate authority
      name = "DigiCert"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        # Policy compliance - trigger at specific percentage (80%)
        lifetime_percentage = 80
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      # Update this with your actual domain
      subject            = "CN=${var.ssl_certificate_domain}"
      # Policy compliance - set expiration date (12 months max)
      validity_in_months = 12

      subject_alternative_names {
        dns_names = [var.ssl_certificate_domain]
      }

      key_usage = [
        "cRLSign",
        "dataEncipherment",
        "digitalSignature",
        "keyAgreement",
        "keyCertSign",
        "keyEncipherment",
      ]

      extended_key_usage = [
        "1.3.6.1.5.5.7.3.1",
        "1.3.6.1.5.5.7.3.2",
      ]
    }
  }

  depends_on = [
    azurerm_role_assignment.key_vault_secrets_user,
    azurerm_role_assignment.key_vault_certificate_user
  ]

  tags = var.common_tags
}

# Application Gateway v2 with WAF
resource "azurerm_application_gateway" "main" {
  name                = "${var.app_name}-appgw"
  resource_group_name = azurerm_resource_group.api.name
  location            = var.location

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 2
  }

  zones = ["1", "2", "3"]

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = data.azurerm_subnet.web.id
  }

  frontend_port {
    name = "port_80"
    port = 80
  }

  frontend_port {
    name = "port_443"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "${var.app_name}-appGwPublicFrontendIp"
    public_ip_address_id = azurerm_public_ip.app_gateway.id
  }

  backend_address_pool {
    name  = "${var.app_name}-containerapp-backend-pool"
    fqdns = [azurerm_container_app.api.latest_revision_fqdn]
  }

  backend_http_settings {
    name                  = "${var.app_name}-containerapp-backend-http-settings"
    cookie_based_affinity = "Disabled"
    path                  = "/"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
    pick_host_name_from_backend_address = true

    probe_name = "${var.app_name}-containerapp-health-probe"
  }

  probe {
    name                                      = "${var.app_name}-containerapp-health-probe"
    protocol                                  = "Https"
    path                                      = "/api/health"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true

    match {
      status_code = ["200-201"]
    }
  }

  http_listener {
    name                           = "${var.app_name}-appGwHttpListener"
    frontend_ip_configuration_name = "${var.app_name}-appGwPublicFrontendIp"
    frontend_port_name             = "port_80"
    protocol                       = "Http"
  }

  http_listener {
    name                           = "${var.app_name}-appGwHttpsListener"
    frontend_ip_configuration_name = "${var.app_name}-appGwPublicFrontendIp"
    frontend_port_name             = "port_443"
    protocol                       = "Https"
    ssl_certificate_name           = "${var.app_name}-appgw-ssl-cert"
  }

  # Azure managed SSL certificate
  ssl_certificate {
    name                = "${var.app_name}-appgw-ssl-cert"
    key_vault_secret_id = azurerm_key_vault_certificate.app_gateway.secret_id
  }

  request_routing_rule {
    name                       = "http-to-https-redirect"
    rule_type                  = "Basic"
    http_listener_name         = "${var.app_name}-appGwHttpListener"
    redirect_configuration_name = "http-to-https-redirect-config"
    priority                   = 100
  }

  request_routing_rule {
    name                       = "${var.app_name}-containerapp-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "${var.app_name}-appGwHttpsListener"
    backend_address_pool_name  = "${var.app_name}-containerapp-backend-pool"
    backend_http_settings_name = "${var.app_name}-containerapp-backend-http-settings"
    priority                   = 200
  }

  redirect_configuration {
    name                 = "http-to-https-redirect-config"
    redirect_type        = "Permanent"
    target_listener_name = "${var.app_name}-appGwHttpsListener"
    include_path         = true
    include_query_string = true
  }


  firewall_policy_id = azurerm_web_application_firewall_policy.main.id

  # Enable autoscaling
  autoscale_configuration {
    min_capacity = 2
    max_capacity = 10
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_apps.id]
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [ 
      # Ignore tags to allow management via Azure Policy
      tags,
      # Ignore SSL certificate to allow for Azure managed certificate updates
      ssl_certificate
    ]
  }

  depends_on = [
    azurerm_container_app.api,
    azurerm_key_vault_certificate.app_gateway,
    azurerm_role_assignment.key_vault_secrets_user,
    azurerm_role_assignment.key_vault_certificate_user
  ]
}
