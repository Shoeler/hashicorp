provider "vault" {
  address = "http://127.0.0.1:8200"
  token   = "root"
}

resource "vault_generic_secret" "example" {
  path = "secret/data/example"

  data_json = <<EOT
{
  "value": "my-secret-value"
}
EOT
}
