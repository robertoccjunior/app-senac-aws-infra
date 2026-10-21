# ==============================================================================
# DECLARAÇÃO DE VARIÁVEIS DO TERRAFORM
# ==============================================================================
# Define a região padrão da AWS onde toda a infraestrutura física/lógica será criada
variable "aws_region" {
  # Tipo primitivo string
  type = string
  # Região padrão: Ohio (us-east-2), escolha com excelente custo/benefício e disponibilidade
  default = "us-east-2"
  # Descrição explicativa do propósito da variável
  description = "Região da AWS onde os recursos serão provisionados (ex: us-east-2 Ohio)"
}

# Define o nome único atribuído ao Cluster EKS (Kubernetes gerenciado da AWS)
variable "cluster_name" {
  # Tipo primitivo string
  type = string
  # Nome base do cluster Kubernetes
  default = "cluster-app-senac-aws"
  # Descrição informativa para os administradores de infraestrutura
  description = "Nome do Cluster Amazon EKS"
}
