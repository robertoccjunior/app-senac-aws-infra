# ==============================================================================
# 1. SECURITY GROUP DO LOAD BALANCER PÚBLICO
# ==============================================================================

# Cria o grupo de segurança de rede (firewall virtual) para o Load Balancer
resource "aws_security_group" "nlb_sg" {
  # Define o nome legível do Security Group no console da AWS
  name = "senac-public-lb-sg"
  # Descrição explicativa da finalidade deste Security Group
  description = "Security group para o Load Balancer publico da aplicacao MVC"
  # Associa o Security Group à Virtual Private Cloud (VPC) do projeto
  vpc_id = module.vpc.vpc_id

  # Bloco de regras de entrada (Ingress) - Define quem pode acessar o Load Balancer
  ingress {
    # Porta TCP inicial de escuta da requisição HTTP
    from_port = 80
    # Porta TCP final de escuta da requisição HTTP
    to_port = 80
    # Protocolo de transporte utilizado na comunicação
    protocol = "tcp"
    # Permite acesso irrestrito vindo de qualquer endereço IPv4 da internet mundial
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Bloco de regras de saída (Egress) - Define para onde o balanceador pode enviar pacotes
  egress {
    # Permite envio a partir de qualquer porta inicial
    from_port = 0
    # Permite envio até qualquer porta final
    to_port = 0
    # O valor -1 indica liberação irrestrita de todos os protocolos de rede na saída
    protocol = "-1"
    # Permite tráfego com destino a qualquer endereço IPv4 (necessário para alcançar os nós)
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# 2. NETWORK LOAD BALANCER (NLB) PÚBLICO
# ==============================================================================

# Provisiona um balanceador de carga de rede na camada 4 voltado para a internet
# resource "aws_lb" "external_lb" {
#   # Nome exclusivo atribuído ao balanceador dentro da região
#   name = "senac-mvc-public-nlb"
#   # Define o balanceador como público (Internet-facing) para acesso via navegador web
#   internal = false
#   # Especifica o tipo de balanceador de carga como de rede (Network Load Balancer)
#   load_balancer_type = "network"
#   # Aloca interfaces de rede públicas para o NLB nas subnets públicas da VPC
#   subnets = module.vpc.public_subnets
#   # Vincula o Security Group criado para aplicar as regras de firewall na borda
#   security_groups = [aws_security_group.nlb_sg.id]
# 
#   # Distribui as conexões uniformemente entre nós em diferentes zonas de disponibilidade
#   enable_cross_zone_load_balancing = true
# }

# ==============================================================================
# 3. TARGET GROUP & REGRAS DE CONEXÃO COM O KUBERNETES (EKS)
# ==============================================================================

# Cria o grupo de alvos onde o NLB entregará o tráfego recebido da internet
resource "aws_lb_target_group" "eks_nodes_tg" {
  # Nome de identificação do grupo de alvos
  name = "senac-app-tg"
  # Porta pública do nó (NodePort) mapeada pelo Service do Kubernetes
  port = 30080
  # Protocolo de transporte utilizado para falar com as instâncias EC2 dos nós
  protocol = "TCP"
  # ID da VPC onde as instâncias EC2 do cluster estão instaladas
  vpc_id = module.vpc.vpc_id
  # O tipo instance registra diretamente as máquinas virtuais EC2 como membros do grupo
  target_type = "instance"

  # Configuração de checagem periódica de saúde (Health Check) das aplicações nos nós
  health_check {
    # Protocolo de checagem de integridade das aplicações
    protocol = "TCP"
    # Porta inspecionada em cada servidor EC2 (porta NodePort do Spring Boot)
    port = "30080"
    # Intervalo de tempo em segundos entre cada checagem de integridade
    interval = 30
    # Número de checagens bem-sucedidas consecutivas para considerar a máquina pronta
    healthy_threshold = 3
    # Número de checagens com falha consecutivas para suspender o tráfego para a máquina
    unhealthy_threshold = 3
  }
}

# Regra de segurança nos nós EC2 permitindo conexões diretas do Security Group do NLB
resource "aws_security_group_rule" "eks_nodes_ingress_nodeport_sg" {
  # Define a regra como entrada de pacotes
  type = "ingress"
  # Porta inicial da liberação
  from_port = 30080
  # Porta final da liberação
  to_port = 30080
  # Protocolo TCP
  protocol = "tcp"
  # ID do Security Group gerenciado que protege os nós trabalhadores do EKS
  security_group_id = module.eks.node_security_group_id
  # Origem permitida: Apenas pacotes que tenham como origem o Security Group do NLB
  source_security_group_id = aws_security_group.nlb_sg.id
  # Descrição descritiva do motivo da regra no painel da AWS
  description = "Permite conexoes originadas do NLB na porta NodePort 30080"
}

# Conecta automaticamente o Auto Scaling Group gerenciado dos nós ao Target Group do NLB
resource "aws_autoscaling_attachment" "eks_nodes_tg_attachment" {
  # Obtém dinamicamente o nome do Auto Scaling Group criado pelo módulo do EKS
  autoscaling_group_name = module.eks.eks_managed_node_groups["app_nodes"].node_group_autoscaling_group_names[0]
  # ARN do Target Group onde os servidores serão registrados automaticamente
  lb_target_group_arn = aws_lb_target_group.eks_nodes_tg.arn
}

# Libera o tráfego de checagem de saúde e tráfego vindo das subnets públicas do NLB
resource "aws_security_group_rule" "eks_nodes_ingress_nodeport_cidrs" {
  # Define o tráfego como de entrada nos nós
  type = "ingress"
  # Porta de destino do NodePort
  from_port = 30080
  # Porta de destino do NodePort
  to_port = 30080
  # Protocolo TCP
  protocol = "tcp"
  # ID do Security Group dos nós do cluster Kubernetes
  security_group_id = module.eks.node_security_group_id
  # Faixas de IP de origem permitidas: Toda a faixa de subnets públicas onde o NLB reside
  cidr_blocks = module.vpc.public_subnets_cidr_blocks
  # Descrição didática da finalidade da regra
  description = "Permite health checks e trafego do NLB publico na porta NodePort 30080"
}

# ==============================================================================
# 4. LISTENER HTTP DO LOAD BALANCER
# ==============================================================================

# Cria o ouvinte (Listener) responsável por escutar as conexões do navegador no balanceador
# resource "aws_lb_listener" "nlb_listener" {
#   # Vincula este listener ao Network Load Balancer público provisionado
#   load_balancer_arn = aws_lb.external_lb.arn
#   # Porta de escuta aberta no Load Balancer para o público (porta web HTTP padrão)
#   port = 80
#   # Protocolo TCP na camada de rede
#   protocol = "TCP"
# 
#   # Ação executada pelo Listener no momento em que um pacote web é recebido
#   default_action {
#     # Encaminha o fluxo de pacotes recebidos
#     type = "forward"
#     # Destino do encaminhamento: O Target Group que entrega aos nós do EKS
#     target_group_arn = aws_lb_target_group.eks_nodes_tg.arn
#   }
# }

# ==============================================================================
# 5. OUTPUT: URL PÚBLICA PARA ACESSO NO NAVEGADOR (THYMELEAF)
# ==============================================================================

# Saída contendo o endereço DNS público para abrir a aplicação web diretamente no navegador
# output "application_public_url" {
#   # Constrói o link completo com o prefixo HTTP e o nome de domínio gerado pelo NLB
#   value = "http://${aws_lb.external_lb.dns_name}"
#   # Descrição amigável para o aluno ou desenvolvedor identificar onde acessar
#   description = "URL Publica do Load Balancer para acessar a aplicacao MVC Thymeleaf no navegador"
# }

# ==============================================================================
# 6. LAMBDA AUTHORIZER (COMENTADO - DESATIVADO PARA PROJETOS MVC TRADICIONAIS)
# ==============================================================================
# O bloco abaixo permanece comentado caso a arquitetura evolua para microsserviços REST:
#
# # Compacta o código-fonte JavaScript do autorizador em arquivo .zip
# # data "archive_file" "lambda_zip" {
#   # Define o tipo de compressão como zip
#   # type        = "zip"
#   # Caminho relativo para o arquivo JS de código-fonte
#   # source_file = "${path.module}/lambda/authorizer.js"
#   # Destino do pacote .zip a ser criado pelo Terraform
#   # output_path = "${path.module}/lambda/authorizer.zip"
# # }
#
# # Cria o perfil IAM para execução da função Lambda
# # resource "aws_iam_role" "lambda_authorizer_role" {
#   # Nome da role no IAM
#   # name = "senac-api-gateway-authorizer-role"
#   # Política de confiança que autoriza a AWS Lambda a assumir este papel
#   # assume_role_policy = jsonencode({
#     # Versão da linguagem de políticas do IAM
#     # Version = "2012-10-17"
#     # Declaração de permissão
#     # Statement = [
#       # {
#         # Ação de assunção de role
#         # Action = "sts:AssumeRole"
#         # Permite a execução
#         # Effect = "Allow"
#         # Serviço confiável
#         # Principal = {
#           # Service = "lambda.amazonaws.com"
#         # }
#       # }
#     # ]
#   # })
# # }
#
# # Vincula a política de permissões de gravação de logs no CloudWatch à Role da Lambda
# # resource "aws_iam_role_policy_attachment" "lambda_logs" {
#   # Associa à Role criada para a Lambda
#   # role       = aws_iam_role.lambda_authorizer_role.name
#   # Política gerenciada oficial de logs básicos para Lambda
#   # policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
# # }
#
# # Provisiona a função Lambda responsável por validar token e chave na borda
# # resource "aws_lambda_function" "authorizer" {
#   # Caminho do pacote zip compilado
#   # filename         = data.archive_file.lambda_zip.output_path
#   # Nome atribuído à função no console da AWS
#   # function_name    = "senac-api-authorizer"
#   # IAM Role que a Lambda utiliza em tempo de execução
#   # role             = aws_iam_role.lambda_authorizer_role.arn
#   # Ponto de entrada do script: arquivo authorizer.js, método exports.handler
#   # handler          = "authorizer.handler"
#   # Hash criptográfico do zip para atualizar a Lambda caso o código mude
#   # source_code_hash = data.archive_file.lambda_zip.output_base64sha256
#   # Versão do ambiente de execução Node.js
#   # runtime          = "nodejs20.x"
#   # Injeta variáveis de ambiente na função
#   # environment {
#     # Mapa de variáveis de ambiente
#     # variables = {
#       # Chave esperada lida por process.env.EXPECTED_API_KEY
#       # EXPECTED_API_KEY = "minha-chave-secreta-senac"
#     # }
#   # }
# # }

# ==============================================================================
# 7. HTTP API GATEWAY & VPC LINK (COMENTADO - DESATIVADO PARA PROJETOS MVC)
# ==============================================================================
#
# # Provisiona o VPC Link conectando o API Gateway às subnets da VPC
# # resource "aws_apigatewayv2_vpc_link" "eks_vpc_link" {
#   # Nome do recurso de VPC Link
#   # name               = "senac-eks-vpc-link"
#   # Security Group aplicado ao túnel de VPC Link
#   # security_group_ids = [aws_security_group.nlb_sg.id]
#   # Subnets privadas por onde o tráfego do túnel transitará
#   # subnet_ids         = module.vpc.private_subnets
# # }
#
# # Cria o API Gateway na modalidade HTTP API
# # resource "aws_apigatewayv2_api" "http_api" {
#   # Nome identificador da API pública
#   # name          = "senac-api-gateway"
#   # Protocolo da API
#   # protocol_type = "HTTP"
# # }
#
# # Permissão permitindo que o API Gateway invoque a função Lambda de autorização
# # resource "aws_lambda_permission" "apigw_authorizer_perm" {
#   # Identificador do comando de autorização
#   # statement_id  = "AllowAPIGatewayInvoke"
#   # Ação permitida pelo IAM
#   # action        = "lambda:InvokeFunction"
#   # Função que será invocada
#   # function_name = aws_lambda_function.authorizer.function_name
#   # Entidade chamadora permitida
#   # principal     = "apigateway.amazonaws.com"
#   # Escopo da API autorizada a invocar
#   # source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/authorizers/*"
# # }
#
# # Registra o autorizador customizado na estrutura do API Gateway
# # resource "aws_apigatewayv2_authorizer" "custom_authorizer" {
#   # ID da API HTTP
#   # api_id                            = aws_apigatewayv2_api.http_api.id
#   # Tipo de autorizador baseado em inspeção de requisição
#   # authorizer_type                   = "REQUEST"
#   # ARN de invocação da Lambda
#   # authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
#   # Versão moderna do payload simplificado
#   # authorizer_payload_format_version = "2.0"
#   # Habilita resposta simples contendo isAuthorized true ou false
#   # enable_simple_responses           = true
#   # Nome descritivo do autorizador
#   # name                              = "lambda-token-and-key-authorizer"
#   # Headers que devem obrigatoriamente estar presentes na chamada HTTP
#   # identity_sources = [
#     # Token Bearer de identificação do usuário
#     # "$request.header.Authorization",
#     # Chave de autorização do sistema chamador
#     # "$request.header.x-api-key"
#   # ]
# # }
#
# # Integração privada do API Gateway com o Listener do NLB interno
# # resource "aws_apigatewayv2_integration" "eks_integration" {
#   # ID da API HTTP
#   # api_id           = aws_apigatewayv2_api.http_api.id
#   # Tipo de integração como proxy reverso HTTP
#   # integration_type = "HTTP_PROXY"
#   # Destino da integração apontando para o ARN do Listener do NLB
#   # integration_uri  = aws_lb_listener.nlb_listener.arn
#   # Método HTTP encaminhado (qualquer um)
#   # integration_method     = "ANY"
#   # Conexão através do túnel de rede
#   # connection_type        = "VPC_LINK"
#   # Identificador do VPC Link criado
#   # connection_id          = aws_apigatewayv2_vpc_link.eks_vpc_link.id
#   # Formato do payload
#   # payload_format_version = "1.0"
# # }
#
# # Rota específica protegida pelo autorizador
# # resource "aws_apigatewayv2_route" "hello_route" {
#   # ID da API HTTP
#   # api_id             = aws_apigatewayv2_api.http_api.id
#   # Método e caminho da rota
#   # route_key          = "GET /api/v1/hello"
#   # Exige autorização customizada pela Lambda
#   # authorization_type = "CUSTOM"
#   # ID do autorizador customizado
#   # authorizer_id      = aws_apigatewayv2_authorizer.custom_authorizer.id
#   # Destino do tráfego validado
#   # target             = "integrations/${aws_apigatewayv2_integration.eks_integration.id}"
# # }
#
# # Rota catch-all abrangendo todas as outras URLs
# # resource "aws_apigatewayv2_route" "default_proxy" {
#   # ID da API HTTP
#   # api_id             = aws_apigatewayv2_api.http_api.id
#   # Captura qualquer método em qualquer rota
#   # route_key          = "ANY /{proxy+}"
#   # Exige autorização customizada pela Lambda
#   # authorization_type = "CUSTOM"
#   # ID do autorizador customizado
#   # authorizer_id      = aws_apigatewayv2_authorizer.custom_authorizer.id
#   # Destino do tráfego validado
#   # target             = "integrations/${aws_apigatewayv2_integration.eks_integration.id}"
# # }
#
# # Estágio de publicação padrão da API
# # resource "aws_apigatewayv2_stage" "default" {
#   # ID da API HTTP
#   # api_id      = aws_apigatewayv2_api.http_api.id
#   # Nome padrão do estágio raiz
#   # name        = "$default"
#   # Publicação automática de mudanças nas rotas
#   # auto_deploy = true
# # }