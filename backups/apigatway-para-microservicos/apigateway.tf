# ==============================================================================
# 1. SECURITY GROUP & LOAD BALANCER DE REDE (NLB INTERNO)
# ==============================================================================
# Security Group para isolar o Load Balancer e controlar portas de comunicação
resource "aws_security_group" "nlb_sg" {
  # Nome do grupo de segurança
  name        = "senac-nlb-sg"
  # Descrição da função do grupo de segurança
  description = "Security group para o NLB interno e VPC Link"
  # ID da rede virtual criada no módulo VPC
  vpc_id      = module.vpc.vpc_id

  # Regra de entrada: Permite requisições HTTP na porta 80 vindas de dentro do range da VPC
  ingress {
    # Porta inicial de escuta
    from_port   = 80
    # Porta final de escuta
    to_port     = 80
    # Protocolo de transporte TCP
    protocol    = "tcp"
    # Permite tráfego restrito aos blocos de IP da própria VPC
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  # Regra de saída: Permite que o balanceador responda pacotes para qualquer destino
  egress {
    # Porta inicial aberta
    from_port   = 0
    # Porta final aberta
    to_port     = 0
    # Protocolo -1 indica todos os protocolos de rede liberados na saída
    protocol    = "-1"
    # Permite saída para qualquer endereço IPv4
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Provisiona um Network Load Balancer (NLB) operando na Camada 4 com altíssima performance
resource "aws_lb" "internal_nlb" {
  # Nome atribuído ao balanceador no console
  name               = "senac-internal-nlb"
  # Define que o NLB é estritamente PRIVADO (não possui IP público exposto para a internet)
  internal           = true
  # Define o tipo de arquitetura como de rede (Network)
  load_balancer_type = "network"
  # Aloca o balanceador exclusivamente nas subnets privadas da VPC
  subnets            = module.vpc.private_subnets
  # Vincula o grupo de segurança criado para filtragem de pacotes
  security_groups    = [aws_security_group.nlb_sg.id]

  # Habilita balanceamento equilibrado entre todas as zonas de disponibilidade
  enable_cross_zone_load_balancing = true
}

# Cria o Target Group apontando para a porta NodePort configurada no Kubernetes
resource "aws_lb_target_group" "eks_nodes_tg" {
  # Nome descritivo do grupo de destino
  name        = "senac-app-tg"
  # Porta pública do nó onde o serviço Spring Boot é exposto internamente no cluster
  port        = 30080
  # Protocolo de camada de transporte
  protocol    = "TCP"
  # VPC onde os alvos residem
  vpc_id      = module.vpc.vpc_id
  # O tipo 'instance' direciona pacotes diretamente para o ID da instância EC2 do nó
  target_type = "instance"

  # Configuração de teste de saúde (Health Check) das aplicações nos nós
  health_check {
    # Protocolo de verificação de disponibilidade
    protocol            = "TCP"
    # Porta verificada em cada servidor EC2
    port                = "30080"
    # Intervalo em segundos entre cada checagem
    interval            = 30
    # Quantidade de testes bem-sucedidos para marcar o nó como saudável
    healthy_threshold   = 3
    # Quantidade de testes falhos consecutivos para marcar o nó como indisponível
    unhealthy_threshold = 3
  }
}

# Regra de firewall nos nós EC2 permitindo conexões diretas do NLB na porta 30080
resource "aws_security_group_rule" "eks_nodes_ingress_nodeport_sg" {
  # Tipo de tráfego de entrada
  type                     = "ingress"
  # Porta inicial da faixa
  from_port                = 30080
  # Porta final da faixa
  to_port                  = 30080
  # Protocolo TCP
  protocol                 = "tcp"
  # ID do Security Group gerenciado dos nós do Kubernetes EKS
  security_group_id        = module.eks.node_security_group_id
  # Origem autorizada: Apenas conexões vindas do Security Group do NLB
  source_security_group_id = aws_security_group.nlb_sg.id
  # Descrição da regra para documentação
  description              = "Permite conexoes originadas do NLB e VPC Link na porta NodePort 30080"
}

# Conecta o Auto Scaling Group gerenciado dos nós ao Target Group do balanceador
resource "aws_autoscaling_attachment" "eks_nodes_tg_attachment" {
  # Identifica dinamicamente o Auto Scaling Group do grupo de nós
  autoscaling_group_name = module.eks.eks_managed_node_groups["app_nodes"].node_group_autoscaling_group_names[0]
  # ARN do grupo de destino onde as instâncias devem ser cadastradas automaticamente
  lb_target_group_arn    = aws_lb_target_group.eks_nodes_tg.arn
}

# Permite que as checagens de saúde do NLB alcancem a porta 30080 a partir de qualquer IP privado
resource "aws_security_group_rule" "eks_nodes_ingress_nodeport_cidrs" {
  # Tipo de regra: entrada
  type              = "ingress"
  # Porta NodePort 30080
  from_port         = 30080
  # Porta NodePort 30080
  to_port           = 30080
  # Protocolo TCP
  protocol          = "tcp"
  # Security Group dos servidores nós do EKS
  security_group_id = module.eks.node_security_group_id
  # Origens autorizadas: Faixa de IPs de todas as subnets privadas
  cidr_blocks       = module.vpc.private_subnets_cidr_blocks
  # Descrição da regra
  description       = "Permite health checks e trafego das subnets privadas na porta NodePort 30080"
}

# Listener do NLB escutando na porta 80 e encaminhando para os nós do Kubernetes
resource "aws_lb_listener" "nlb_listener" {
  # ARN do Load Balancer criado anteriormente
  load_balancer_arn = aws_lb.internal_nlb.arn
  # Porta em que o Load Balancer escuta internamente
  port              = 80
  # Protocolo TCP
  protocol          = "TCP"

  # Ação padrão realizada ao receber um pacote
  default_action {
    # Encaminha o pacote adiante
    type             = "forward"
    # Destino do encaminhamento: O Target Group dos nós
    target_group_arn = aws_lb_target_group.eks_nodes_tg.arn
  }
}

# ==============================================================================
# 2. LAMBDA AUTHORIZER (VALIDAÇÃO DE TOKEN + X-API-KEY NA BORDA)
# ==============================================================================
# Empacota automaticamente o código JavaScript em um arquivo .zip local durante o provisionamento
data "archive_file" "lambda_zip" {
  # Formato de compressão padrão zip
  type        = "zip"
  # Caminho do código fonte local do autorizador JavaScript
  source_file = "${path.module}/lambda/authorizer.js"
  # Destino do arquivo compactado gerado
  output_path = "${path.module}/lambda/authorizer.zip"
}

# Cria a IAM Role com as permissões de execução para o serviço AWS Lambda
resource "aws_iam_role" "lambda_authorizer_role" {
  # Nome da IAM Role
  name = "senac-api-gateway-authorizer-role"

  # Política de confiança que autoriza a AWS Lambda a assumir este papel
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permissão para assumir o papel
        Action = "sts:AssumeRole"
        # Permite a ação
        Effect = "Allow"
        # Entidade confiável da AWS
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Anexa a política gerenciada da AWS que permite à Lambda gravar logs no Amazon CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  # Role à qual a permissão será anexada
  role       = aws_iam_role.lambda_authorizer_role.name
  # ARN da política oficial básica de execução de Lambdas
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Cria a função Serverless AWS Lambda responsável por validar credenciais
resource "aws_lambda_function" "authorizer" {
  # Caminho do arquivo compactado contendo o código fonte
  filename         = data.archive_file.lambda_zip.output_path
  # Nome da função na AWS
  function_name    = "senac-api-authorizer"
  # ARN da Role criada com permissões para a função
  role             = aws_iam_role.lambda_authorizer_role.arn
  # Ponto de entrada da execução: arquivo authorizer.js, método exports.handler
  handler          = "authorizer.handler"
  # Hash sha256 para detectar modificações no código e disparar re-deploy automático
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  # Ambiente de execução estável com Node.js versão 20
  runtime          = "nodejs20.x"

  # Variáveis de ambiente injetadas no container da Lambda
  environment {
    variables = {
      # Chave de API esperada lida por process.env.EXPECTED_API_KEY
      EXPECTED_API_KEY = "minha-chave-secreta-senac"
    }
  }
}

# ==============================================================================
# 3. HTTP API GATEWAY, VPC LINK & INTEGRAÇÕES
# ==============================================================================
# Provisiona o VPC Link: Túnel seguro que conecta o API Gateway público aos recursos da VPC privada
resource "aws_apigatewayv2_vpc_link" "eks_vpc_link" {
  # Nome atribuído ao VPC Link
  name               = "senac-eks-vpc-link"
  # Security Group atribuído à interface de rede do VPC Link
  security_group_ids = [aws_security_group.nlb_sg.id]
  # Subnets privadas onde o túnel será conectado
  subnet_ids         = module.vpc.private_subnets
}

# Cria a instância pública do AWS API Gateway (protocolo moderno HTTP API v2)
resource "aws_apigatewayv2_api" "http_api" {
  # Nome público da API
  name          = "senac-api-gateway"
  # Tipo de protocolo de comunicação
  protocol_type = "HTTP"
}

# Concede autorização explícita para o API Gateway invocar a função Lambda do autorizador
resource "aws_lambda_permission" "apigw_authorizer_perm" {
  # Identificador único da permissão dentro da Lambda
  statement_id  = "AllowAPIGatewayInvoke"
  # Ação autorizada: invocação de função
  action        = "lambda:InvokeFunction"
  # Função Lambda que receberá a permissão
  function_name = aws_lambda_function.authorizer.function_name
  # Entidade autorizada a chamar: Serviço de API Gateway da AWS
  principal     = "apigateway.amazonaws.com"
  # [id-conta] Escopo restrito garantindo que apenas os autorizadores desta API possam chamá-la
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/authorizers/*"
}

# Cadastra o autorizador customizado dentro do motor do API Gateway
resource "aws_apigatewayv2_authorizer" "custom_authorizer" {
  # ID do API Gateway proprietário do autorizador
  api_id                            = aws_apigatewayv2_api.http_api.id
  # Tipo de autorizador baseado em inspeção de cabeçalhos da requisição
  authorizer_type                   = "REQUEST"
  # Endereço de invocação ARN da função Lambda
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  # Versão do payload JSON trafegado para a Lambda (v2.0 simplificado)
  authorizer_payload_format_version = "2.0"
  # Habilita retorno simplificado contendo o campo booleano 'isAuthorized'
  enable_simple_responses           = true
  # Nome descritivo do autorizador
  name                              = "lambda-token-and-key-authorizer"

  # Define os cabeçalhos obrigatórios que o Gateway exige antes mesmo de invocar a Lambda
  identity_sources = [
    # Cabeçalho de autorização contendo o token de identidade do usuário
    "$request.header.Authorization",
    # Cabeçalho contendo a chave de acesso do cliente
    "$request.header.x-api-key"
  ]
}

# Integração de Proxy Privado conectando a borda HTTP API ao Listener do NLB interno
resource "aws_apigatewayv2_integration" "eks_integration" {
  # ID do API Gateway
  api_id           = aws_apigatewayv2_api.http_api.id
  # Tipo de integração como proxy transparente HTTP
  integration_type = "HTTP_PROXY"
  # Destino do tráfego: O Listener privado na porta 80 do NLB
  integration_uri  = aws_lb_listener.nlb_listener.arn

  # Método HTTP repassado (ANY aceita GET, POST, PUT, DELETE, etc.)
  integration_method     = "ANY"
  # Define que a conexão trafega por dentro do túnel privado
  connection_type        = "VPC_LINK"
  # ID do VPC Link configurado
  connection_id          = aws_apigatewayv2_vpc_link.eks_vpc_link.id
  # Versão do payload de repasse transparente para o Kubernetes
  payload_format_version = "1.0"
}

# Rota pública protegida pelo Authorizer para o endpoint principal de testes
resource "aws_apigatewayv2_route" "hello_route" {
  # ID do API Gateway
  api_id             = aws_apigatewayv2_api.http_api.id
  # Chave da rota: Método GET no caminho /api/v1/hello
  route_key          = "GET /api/v1/hello"
  # Tipo de autorização: 'CUSTOM' ativa o Lambda Authorizer; 'NONE' deixa a rota 100% aberta
  authorization_type = "CUSTOM"
  # ID do autorizador customizado responsável por validar as chamadas nesta rota
  authorizer_id      = aws_apigatewayv2_authorizer.custom_authorizer.id
  # Encaminha as requisições autenticadas para a integração com o cluster Kubernetes
  target             = "integrations/${aws_apigatewayv2_integration.eks_integration.id}"
}

# Rota catch-all protegida pelo Authorizer para qualquer outro endpoint da aplicação
resource "aws_apigatewayv2_route" "default_proxy" {
  # ID do API Gateway
  api_id             = aws_apigatewayv2_api.http_api.id
  # Captura qualquer verbo HTTP em qualquer sub-caminho da API
  route_key          = "ANY /{proxy+}"
  # Tipo de autorização: 'CUSTOM' ativa a Lambda de validação
  authorization_type = "CUSTOM"
  # Vincula o autorizador customizado a todas as rotas da aplicação
  authorizer_id      = aws_apigatewayv2_authorizer.custom_authorizer.id
  # Direciona para o microserviço
  target             = "integrations/${aws_apigatewayv2_integration.eks_integration.id}"
}

# Estágio de publicação (Stage) da API com implantação automática ativada
resource "aws_apigatewayv2_stage" "default" {
  # ID do API Gateway
  api_id      = aws_apigatewayv2_api.http_api.id
  # Estágio $default responde diretamente na raiz da URL pública gerada
  name        = "$default"
  # Qualquer alteração nas rotas é refletida imediatamente em produção
  auto_deploy = true
}

# Saída que exibe a URL pública do API Gateway para testes no Postman e pelos alunos
output "api_gateway_endpoint" {
  # Valor dinâmico da URL base de invocação
  value       = aws_apigatewayv2_stage.default.invoke_url
  # Descrição informativa do endpoint
  description = "URL Pública do AWS API Gateway para consumo do microsserviço"
}
