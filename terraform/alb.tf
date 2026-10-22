# ==============================================================================
# APPLICATION LOAD BALANCER (ALB) PARA OS NÓS DO NODE GROUP "ng-senac-app"
# ==============================================================================
# O ALB fica nas subnets públicas e encaminha o tráfego HTTP para a porta NodePort
# dos nós EC2 (subnets privadas). No Kubernetes, o Service da aplicação deve ser
# do tipo NodePort usando a mesma porta definida em var.app_node_port.

# Security Group do ALB: aceita HTTP da internet
resource "aws_security_group" "alb" {
  name        = "alb-senac-app-sg"
  description = "Permite acesso HTTP publico ao ALB da aplicacao Senac"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "sg-alb-senac-app"
  }
}

# Entrada: HTTP (80) vindo de qualquer origem
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP publico"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# Saída: ALB só fala com a porta NodePort dos nós
resource "aws_vpc_security_group_egress_rule" "alb_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Trafego do ALB para os nos EKS"
  ip_protocol                  = "tcp"
  from_port                    = var.app_node_port
  to_port                      = var.app_node_port
  referenced_security_group_id = module.eks.node_security_group_id
}

# Libera nos nós EKS a porta NodePort apenas para o Security Group do ALB
resource "aws_vpc_security_group_ingress_rule" "nodes_from_alb" {
  security_group_id            = module.eks.node_security_group_id
  description                  = "NodePort da aplicacao vindo do ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.app_node_port
  to_port                      = var.app_node_port
  referenced_security_group_id = aws_security_group.alb.id
}

# Load Balancer público nas subnets públicas
resource "aws_lb" "app" {
  name               = "alb-senac-app"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  tags = {
    Name = "alb-senac-app"
  }
}

# Target Group do tipo instance: registra as EC2 do node group na porta NodePort
resource "aws_lb_target_group" "app" {
  name        = "tg-senac-app"
  port        = var.app_node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = var.app_health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Listener HTTP 80 encaminhando tudo para o Target Group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Vincula o Auto Scaling Group do node group ao Target Group:
# toda EC2 criada/removida pelo ASG é registrada/removida automaticamente no ALB
resource "aws_autoscaling_attachment" "app_nodes" {
  autoscaling_group_name = module.eks.eks_managed_node_groups["app_nodes"].node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.app.arn
}

# DNS público do ALB para acessar a aplicação
output "alb_dns_name" {
  description = "DNS publico do Application Load Balancer"
  value       = aws_lb.app.dns_name
}

# URL pronta para colar no navegador (HTTP, sem certificado)
output "alb_url" {
  description = "URL HTTP da aplicacao via ALB"
  value       = "http://${aws_lb.app.dns_name}"
}
