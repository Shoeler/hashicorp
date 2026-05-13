# --- PostgreSQL (backing store for dynamic secrets demo) ---

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgres"
    namespace = "default"
    labels    = { app = "postgres" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "postgres" }
    }
    template {
      metadata {
        labels = { app = "postgres" }
      }
      spec {
        container {
          name  = "postgres"
          image = "postgres:16-alpine"
          port {
            container_port = 5432
          }
          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value = "postgres"
          }
          env {
            name  = "POSTGRES_DB"
            value = "app"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "postgres"
    namespace = "default"
  }
  spec {
    selector = { app = "postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
  depends_on = [kubernetes_deployment.postgres]
}

# --- Vault Database Secrets Engine ---

resource "vault_mount" "database" {
  path = "database"
  type = "database"

  depends_on = [helm_release.vault]
}

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "flask-app-db"
  allowed_roles = ["flask-app-db-role"]

  postgresql {
    connection_url = "postgresql://postgres:postgres@postgres.default.svc:5432/app?sslmode=disable"
  }

  depends_on = [
    vault_mount.database,
    kubernetes_service.postgres,
  ]
}

resource "vault_database_secret_backend_role" "flask_app_db" {
  backend = vault_mount.database.path
  name    = "flask-app-db-role"
  db_name = vault_database_secret_backend_connection.postgres.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\"",
  ]
  revocation_statements = [
    "DROP ROLE IF EXISTS \"{{name}}\"",
  ]

  default_ttl = 3600
  max_ttl     = 86400
}
