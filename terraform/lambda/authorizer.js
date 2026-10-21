// ==============================================================================
// LAMBDA AUTHORIZER (HTTP API v2 PAYLOAD 2.0)
// ==============================================================================
// Função de autorização executada na borda pelo API Gateway antes de chegar ao microserviço
// Usa a sintaxe padrão CommonJS (exports.handler) para compatibilidade nativa com Node.js na AWS
exports.handler = async (event) => {
  // Registra o evento recebido no console para auditoria e logs no Amazon CloudWatch
  console.log("Recebendo evento para autorização:", JSON.stringify(event));

  // Bloco try-catch para capturar qualquer exceção e impedir queda não tratada da função
  try {
    // Extrai o mapa de cabeçalhos HTTP da requisição; caso nulo, inicializa como objeto vazio
    // No formato Payload 2.0 do HTTP API da AWS, todos os nomes de cabeçalhos chegam em letras minúsculas
    const headers = event.headers || {};

    // Obtém o cabeçalho 'authorization' contendo as credenciais do usuário (ex: Bearer token)
    const authorization = headers["authorization"] || "";

    // Obtém o cabeçalho 'x-api-key' contendo a chave de identificação do parceiro/sistema chamador
    const apiKey = headers["x-api-key"] || "";

    // Carrega a chave esperada via variável de ambiente da Lambda; fallback para valor padrão
    const EXPECTED_API_KEY = process.env.EXPECTED_API_KEY || "minha-chave-secreta-senac";

    // --------------------------------------------------------------------------
    // ETAPA 1: VALIDAÇÃO DA CHAVE DE API (AUTORIZAÇÃO DO CANAL/CLIENTE)
    // --------------------------------------------------------------------------
    // Checa se a chave enviada no cabeçalho x-api-key confere exatamente com a configurada
    const isApiKeyValida = apiKey === EXPECTED_API_KEY;

    // --------------------------------------------------------------------------
    // ETAPA 2: VALIDAÇÃO DO TOKEN BEARER (AUTENTICAÇÃO DO USUÁRIO)
    // --------------------------------------------------------------------------
    // Checa se o cabeçalho começa com o prefixo 'Bearer ' e possui comprimento mínimo
    // Em produção bancária/corporativa, decodifica-se e valida-se a assinatura JWT com chaves públicas (JWKS)
    const isTokenValido = authorization.startsWith("Bearer ") && authorization.length > 10;

    // --------------------------------------------------------------------------
    // ETAPA 3: DECISÃO DE ACESSO
    // --------------------------------------------------------------------------
    // Se ambos os critérios forem estritamente atendidos, libera a requisição para o Kubernetes
    if (isApiKeyValida && isTokenValido) {
      // Registra no CloudWatch que o acesso foi concedido com sucesso
      console.log("Autorização concedida com sucesso.");
      // Retorna a resposta no formato simples esperado pelo API Gateway HTTP API
      return {
        // Campo booleano obrigatório informando à AWS que o acesso é permitido
        isAuthorized: true,
        // Informações contextuais opcionais repassadas para os logs ou próximos estágios
        context: {
          user: "authenticated-user"
        }
      };
    }

    // Se qualquer um dos requisitos falhar, registra no log a tentativa frustrada
    console.warn("Autorização negada: Headers não atendem aos critérios de segurança.");
    // Retorna explicitamente isAuthorized: false para o API Gateway barrar com 403 Forbidden
    return {
      isAuthorized: false
    };

  } catch (err) {
    // Captura qualquer erro inesperado durante a execução do código JS
    console.error("Erro interno durante a execução do autorizador:", err);
    // Em caso de falha de execução, adota postura segura (Fail-Close) negando o acesso
    return {
      isAuthorized: false
    };
  }
};
