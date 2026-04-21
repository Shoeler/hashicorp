# Build and push the Flask app image before deploying.
# Triggers re-build when Dockerfile or app source changes.
resource "null_resource" "flask_image" {
  triggers = {
    dockerfile = filemd5("${path.module}/flask-app/Dockerfile")
    app        = filemd5("${path.module}/flask-app/app.py")
  }

  provisioner "local-exec" {
    command = "podman build -t localhost:5001/flask-app:${var.flask_image_tag} ${path.module}/flask-app && podman push localhost:5001/flask-app:${var.flask_image_tag} --tls-verify=false"
  }

  depends_on = [helm_release.registry]
}

resource "helm_release" "flask_app" {
  name  = "flask-app"
  chart = "${path.module}/flask-app/chart"

  set {
    name  = "image.repository"
    value = "${local.registry_internal_address}/flask-app"
  }
  set {
    name  = "image.pullPolicy"
    value = "Always"
  }
  set {
    name  = "image.tag"
    value = var.flask_image_tag
  }

  depends_on = [
    null_resource.flask_image,
    kubernetes_manifest.vault_static_secret,
    kubernetes_manifest.gateway_nodeports_http,
  ]
}
