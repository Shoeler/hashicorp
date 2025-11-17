# Vault with Docker Compose and Terraform

This repository provides a simple setup to run HashiCorp Vault in a Docker container using Docker Compose, and manage its configuration with Terraform.

## Prerequisites

- Docker
- Docker Compose
- Terraform

## Usage

1. **Start Vault:**

   ```bash
   docker-compose up -d
   ```

   This will start a Vault server in development mode, listening on `http://127.0.0.1:8200`. The root token is set to `root`.

2. **Initialize and Apply Terraform:**

   ```bash
   terraform init
   terraform apply
   ```

   This will configure the Vault provider and create a secret at `secret/data/example`.

3. **Verify the Secret:**

   You can verify the secret was created by running:

   ```bash
   docker-compose exec vault vault read secret/data/example
   ```

## Cleanup

To stop and remove the Vault container, run:

```bash
docker-compose down
```
