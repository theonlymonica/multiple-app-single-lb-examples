locals {
  name  = "autoTGdemo"
  path1 = "/test1"
  path2 = "/test2"
}

module "load_balancer_controller" {
  source             = "DNXLabs/eks-lb-controller/aws"
  version            = "0.6.0"
  helm_chart_version = "1.4.2"

  cluster_identity_oidc_issuer     = module.eks.cluster_oidc_issuer_url
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn
  cluster_name                     = module.eks.cluster_id

  namespace        = "kube-system"
  create_namespace = false

}

resource "aws_lb" "alb" {
  name                       = "${local.name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = module.vpc.public_subnets
  enable_deletion_protection = false
  security_groups            = [aws_security_group.alb.id]
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Allow ALB inbound traffic"
  vpc_id      = module.vpc.vpc_id

  tags = {
    "Name" = "${local.name}-alb-sg"
  }

  ingress {
    description = "allowed IPs"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["93.41.18.207/32"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_lb_target_group" "alb_tg1" {
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-tg1"
  }

  health_check {
    path                = "/"
    port                = "traffic-port"
    interval            = 5
    timeout             = 3
    unhealthy_threshold = 10
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "alb_tg2" {
  port        = 9090
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-tg2"
  }

  health_check {
    path                = "/"
    port                = "traffic-port"
    interval            = 5
    timeout             = 3
    unhealthy_threshold = 10
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "alb_listener_http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Internal Server Error"
      status_code  = "500"
    }
  }
}

resource "aws_lb_listener_rule" "alb_listener_rule_forwarding_path1" {
  listener_arn = aws_lb_listener.alb_listener_http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg1.arn
  }

  condition {
    path_pattern {
      values = [local.path1]
    }
  }
}

resource "aws_lb_listener_rule" "alb_listener_rule_forwarding_path2" {
  listener_arn = aws_lb_listener.alb_listener_http.arn
  priority     = 101

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg2.arn
  }

  condition {
    path_pattern {
      values = [local.path2]
    }
  }
}

resource "aws_security_group_rule" "eks_node_alb_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = aws_security_group.alb.id
}
