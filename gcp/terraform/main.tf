provider "google" {
  project = "myprojectID"
  region  = "europe-west3"
  zone    = "europe-west3-c"
}

data "google_client_config" "default" {}

data "google_compute_zones" "available" {}

data "google_compute_default_service_account" "default" {}

locals {
  name    = "cool-app-name"
  domains = ["example.org", "example.com"]
  authorized_networks = [
    { cidr_block   = "0.0.0.0/0",
      display_name = "change_me"
    }
  ]
}

module "enabled_google_apis" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "~> 11.3"

  project_id                  = data.google_client_config.default.project
  disable_services_on_destroy = false

  activate_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "gkehub.googleapis.com",
    "anthosconfigmanagement.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = ">= 4.0.1, < 5.0.0"

  project_id   = data.google_client_config.default.project
  network_name = "${local.name}-vpc"

  subnets = [
    {
      subnet_name   = "${local.name}-subnet"
      subnet_ip     = "10.0.0.0/17"
      subnet_region = data.google_client_config.default.region
    },
  ]

  secondary_ranges = {
    ("${local.name}-subnet") = [
      {
        range_name    = "${local.name}-pods-range"
        ip_cidr_range = "192.168.0.0/18"
      },
      {
        range_name    = "${local.name}-services-range"
        ip_cidr_range = "192.168.64.0/18"
      },
    ]
  }
}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google"
  project_id                 = module.enabled_google_apis.project_id
  name                       = "${local.name}-gke"
  kubernetes_version         = "1.22"
  region                     = data.google_client_config.default.region
  zones                      = data.google_compute_zones.available.names
  network                    = module.vpc.network_name
  subnetwork                 = "${local.name}-subnet"
  ip_range_pods              = "${local.name}-pods-range"
  ip_range_services          = "${local.name}-services-range"
  add_cluster_firewall_rules = true
  http_load_balancing        = true
  network_policy             = false
  horizontal_pod_autoscaling = true
  filestore_csi_driver       = false
  initial_node_count         = 1
  remove_default_node_pool   = true
  master_authorized_networks = local.authorized_networks

  node_pools = [
    {
      name            = "${local.name}-node-pool"
      machine_type    = "e2-medium"
      node_locations  = join(",", data.google_compute_zones.available.names)
      min_count       = 1
      max_count       = 3
      local_ssd_count = 0
      spot            = false
      disk_size_gb    = 20
      disk_type       = "pd-standard"
      image_type      = "COS_CONTAINERD"
      enable_gcfs     = false
      enable_gvnic    = false
      auto_repair     = true
      auto_upgrade    = false
      service_account = data.google_compute_default_service_account.default.email
      preemptible     = true
      version         = "1.22.12-gke.300"
    },
  ]
}

resource "google_compute_firewall" "firewall" {
  name    = "${local.name}-firewall"
  network = module.vpc.network_name
  allow {
    protocol = "tcp"
    ports    = [80]
  }
  # GCP ranges for health checks
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

resource "google_compute_health_check" "health_check" {
  name                = "${local.name}-health-check"
  check_interval_sec  = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
  timeout_sec         = 1

  tcp_health_check {
    port = 80
  }

  log_config {
    enable = true
  }
}

resource "google_compute_backend_service" "backend_apache" {
  project = module.enabled_google_apis.project_id
  name    = "${local.name}-backend-apache"

  dynamic "backend" {
    for_each = local.neg_apache
    content {
      group          = backend.value
      balancing_mode = "RATE"
      max_rate       = 100
    }
  }

  log_config {
    enable      = true
    sample_rate = 1
  }

  protocol      = "HTTP"
  health_checks = [google_compute_health_check.health_check.id]

  lifecycle {
    prevent_destroy = false
  }

  depends_on = [kubernetes_service.apache, time_sleep.post_apache_service]
}

resource "google_compute_backend_service" "backend_nginx" {
  project = module.enabled_google_apis.project_id
  name    = "${local.name}-backend-nginx"

  dynamic "backend" {
    for_each = local.neg_nginx
    content {
      group          = backend.value
      balancing_mode = "RATE"
      max_rate       = 100
    }
  }

  log_config {
    enable      = true
    sample_rate = 1
  }

  protocol      = "HTTP"
  health_checks = [google_compute_health_check.health_check.id]

  lifecycle {
    prevent_destroy = false
  }

  depends_on = [kubernetes_service.nginx, time_sleep.post_nginx_service]
}

resource "google_compute_global_address" "ext_lb_ip" {
  project      = module.enabled_google_apis.project_id
  name         = "ext-lb-ip"
  address_type = "EXTERNAL"
}

resource "google_compute_url_map" "http_url_map" {
  project         = module.enabled_google_apis.project_id
  name            = "${local.name}-loadbalancer"
  default_service = google_compute_backend_bucket.static_site.id

  host_rule {
    hosts        = local.domains
    path_matcher = "all"
  }

  path_matcher {
    name            = "all"
    default_service = google_compute_backend_bucket.static_site.id

    path_rule {
      paths = ["/apache"]
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/"
        }
      }
      service = google_compute_backend_service.backend_apache.id
    }

    path_rule {
      paths = ["/nginx"]
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/"
        }
      }
      service = google_compute_backend_service.backend_nginx.id
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_http_proxy" "http_proxy" {
  project = module.enabled_google_apis.project_id
  name    = "http-proxy"
  url_map = google_compute_url_map.http_url_map.self_link
}

resource "google_compute_global_forwarding_rule" "http_fw_rule" {
  project               = module.enabled_google_apis.project_id
  name                  = "http-fw-rule"
  port_range            = 80
  target                = google_compute_target_http_proxy.http_proxy.self_link
  load_balancing_scheme = "EXTERNAL"
  ip_address            = google_compute_global_address.ext_lb_ip.address
}

locals {
  namespace       = "default"
  neg_name_apache = "apache"
  neg_apache      = formatlist("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/networkEndpointGroups/%s", module.enabled_google_apis.project_id, data.google_compute_zones.available.names, local.neg_name_apache)
  neg_name_nginx  = "nginx"
  neg_nginx       = formatlist("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/networkEndpointGroups/%s", module.enabled_google_apis.project_id, data.google_compute_zones.available.names, local.neg_name_nginx)
}

resource "kubernetes_service" "apache" {
  metadata {
    name      = "apache"
    namespace = local.namespace
    annotations = {
      "cloud.google.com/neg" = "{\"exposed_ports\": {\"80\":{\"name\": \"${local.neg_name_apache}\"}}}"
      "cloud.google.com/neg-status" = jsonencode(
        {
          network_endpoint_groups = {
            "80" = local.neg_name_apache
          }
          zones = data.google_compute_zones.available.names
        }
      )
    }
  }
  spec {
    port {
      name        = "http"
      protocol    = "TCP"
      port        = 80
      target_port = "80"
    }
    selector = {
      app = "apache"
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_service" "nginx" {
  metadata {
    name      = "nginx"
    namespace = local.namespace
    annotations = {
      "cloud.google.com/neg" = "{\"exposed_ports\": {\"80\":{\"name\": \"${local.neg_name_nginx}\"}}}"
      "cloud.google.com/neg-status" = jsonencode(
        {
          network_endpoint_groups = {
            "80" = local.neg_name_nginx
          }
          zones = data.google_compute_zones.available.names
        }
      )
    }
  }
  spec {
    port {
      name        = "http"
      protocol    = "TCP"
      port        = 80
      target_port = "80"
    }
    selector = {
      app = "nginx"
    }
    type = "ClusterIP"
  }
}

resource "time_sleep" "post_apache_service" {
  create_duration = "60s"
  depends_on      = [kubernetes_service.apache]
}

resource "time_sleep" "post_nginx_service" {
  create_duration = "60s"
  depends_on      = [kubernetes_service.nginx]
}

resource "google_storage_bucket" "static_site" {
  name          = "${local.name}-static-bucket"
  location      = "EU"
  force_destroy = true

  uniform_bucket_level_access = true

  website {
    main_page_suffix = "404.html"
    not_found_page   = "404.html"
  }
}

resource "google_storage_bucket_access_control" "public_rule" {
  bucket = google_storage_bucket.static_site.name
  role   = "READER"
  entity = "allUsers"
}

resource "google_storage_bucket_object" "page404" {
  name    = "404.html"
  content = "<h1>Error 404</h1>"
  bucket  = google_storage_bucket.static_site.name
}

resource "google_compute_backend_bucket" "static_site" {
  name        = "${local.name}-static-bucket"
  bucket_name = google_storage_bucket.static_site.name
}
