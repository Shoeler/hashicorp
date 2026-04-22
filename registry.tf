resource "helm_release" "registry" {
  name       = "registry"
  repository = "https://twuni.github.io/docker-registry.helm/"
  chart      = "docker-registry"
  version    = "2.2.1"

  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "service.nodePort"
    value = var.registry_node_port
  }
  set {
    name  = "service.port"
    value = "5000"
  }
  set {
    name  = "persistence.enabled"
    value = "false"
  }

  wait = true
}
