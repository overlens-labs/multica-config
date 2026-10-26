# Onboarding de agentes como código

Este diretório transforma em código o runbook de onboarding de agentes (OVER-7), seguindo a decisão registrada na OVER-9. Ele serve para qualquer organização: org, domínio, região e IDs entram por `<org>.tfvars`. O arquivo [`overlens.tfvars`](overlens.tfvars) é o exemplo da Overlens e não contém segredo.

| O quê | Onde |
|---|---|
| Bucket de state + chave KMS (uma vez por org) | `scripts/bootstrap.sh` |
| AWS, Infisical, Neon | `infra/` (OpenTofu), aplicado pelo pipeline (seção 6) |
| Repos na instalação da GitHub App de cada agente | `infra/app-installations/` (OpenTofu, `apply` local do owner) |
| Agente no Multica (env, MCP, skill, concorrência) | `scripts/sync-multica.sh` → `configure-agent.sh` |
| Tokens do Railway | `scripts/railway-tokens.sh` (o provider não cobre) |
| Agentes, skills e autopilots de um workspace novo | `scripts/multica-workspace.py` + `multica/<org>/` |
| Criar a GitHub App, integração do Notion e sync Vercel ← Infisical | cliques manuais (seção 3.4) |

**Regras que o código garante:**
- Mudança em `infra/` só chega ao ambiente real por PR: o pipeline roda `plan` no PR (com aprovação do code owner) e `apply` do mesmo plano depois do merge (seção 6). Os agentes escrevem e revisam este código, mas nunca aplicam nem veem credencial admin. A exceção é `infra/app-installations/`, aplicado localmente pelo owner.
- Credenciais geradas (client secret do Infisical, access key AWS, senha do Neon) vão direto para o Infisical. Nenhum output não-`sensitive` carrega segredo.
- O state fica no bucket `<org>-terraform-state`, com lock nativo (`use_lockfile`) e **criptografia nativa do OpenTofu** com a chave KMS `alias/<org>-terraform-state` (`enforced = true`: nunca grava state ou plan em claro). O state contém segredos (access keys, client secrets, senha do Neon), e é por isso que tanto a chave quanto o bucket ficam restritos ao admin.

## 1. Pré-requisitos (máquina do admin)

> Com o pipeline (seção 6) no ar, a máquina do admin só precisa disto para o bootstrap, para `infra/app-installations/` e como break-glass.

- OpenTofu ≥ 1.9 (testado com 1.9.4 e 1.13.2), AWS CLI v2, `jq`, `python3`, CLI do Infisical, CLI do `multica` (logado no workspace certo), `notion-mcp-server` no `PATH` (o `configure-agent.sh` exige).
- Credenciais admin **no ambiente**, nunca em arquivo versionado:

| Variável | Para quê |
|---|---|
| `AWS_PROFILE` (ou `AWS_ACCESS_KEY_ID`/...) | conta AWS da org; o provider recusa outra conta (`allowed_account_ids`) |
| `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` / `_SECRET` | machine identity **admin** do Infisical (org admin) |
| `NEON_API_KEY` | só se algum app tiver `neon` |
| `GITHUB_TOKEN` | stack principal: qualquer token com leitura (no pipeline, token da App `overlens-infra-admin`). `infra/app-installations/`: token de **usuário** owner da org, porque adicionar repos a uma instalação não funciona com token de App |
| `RAILWAY_API_TOKEN` | só para `railway-tokens.sh` |

## 2. Primeira vez numa organização

```bash
# 2.1 Bucket + KMS (idempotente; repita sem medo)
scripts/bootstrap.sh --org <org> --region <regiao> [--admin-arn arn:aws:iam::<conta>:role/<admin>]

# 2.2 Valores da org
cp infra/overlens.tfvars infra/<org>.tfvars   # edite tudo; *.tfvars fora o exemplo é ignorado pelo git
cd infra
tofu init -var-file=<org>.tfvars              # o backend usa var.org e var.aws_region
tofu plan -var-file=<org>.tfvars -out=tfplan  # o plano também sai cifrado
tofu apply -var-file=<org>.tfvars tfplan     # OpenTofu >= 1.10 (ver nota)

# 2.3 Repos das Apps dos agentes (state próprio)
cd app-installations
tofu init -var-file=../<org>.tfvars
tofu apply -var-file=../<org>.tfvars [-var adopt_existing=true]
```

> **Nota:** o backend e a criptografia usam variáveis, então aplicar um plano salvo exige repetir o `-var-file`, e o OpenTofu 1.9 recusa variáveis com plano salvo (`Can't set variables when applying a saved plan`). Na 1.9, use `tofu apply -var-file=<org>.tfvars` sem plano salvo. O pipeline fixa a 1.13.2.

Depois do `apply`:

1. **Cliques manuais** (seção 3.4): private key da GitHub App e `NOTION_TOKEN` em `/<agent>` no Infisical.
2. **Workspace Multica novo** (só ao replicar em outra org): `scripts/multica-workspace.py bootstrap multica/<org> --dry-run`, revise e rode sem `--dry-run`. Ele recria skills, agentes (instruções, concorrência, runtime por provider) e autopilots com os crons. O template é dono dos triggers `schedule`: mudar um cron no `.json` substitui o agendamento antigo, e triggers `schedule` criados à mão nesse autopilot são removidos. Webhooks não são tocados. Para gerar `multica/<org>/` a partir de um workspace existente, use `scripts/multica-workspace.py export multica/<org>`.
3. **Multica:** `scripts/sync-multica.sh --var-file infra/<org>.tfvars --dry-run`, depois sem `--dry-run`. Ele grava nas envs do agente só a machine identity, configura o MCP do Notion e ajusta concorrência e skills. Use `--railway` para criar também os tokens do Railway.
4. **Smoke test** de cada agente, como no runbook §9 (Validar).

> O `sync-multica.sh` vem depois dos cliques manuais, e não antes como estava na OVER-9, porque o `configure-agent.sh` falha se o `NOTION_TOKEN` ainda não estiver no Infisical. Essa verificação evita configurar um MCP quebrado.

### 2.1 Adotar o que já foi criado à mão

`imports.tf` adota recursos existentes com blocos `import`, guiado por `var.imports`. Uma org que começa do zero deixa `imports = {}`. Depois do primeiro `apply` os blocos não fazem nada, então as entradas podem ficar no tfvars.

| Recurso existente | Como é adotado |
|---|---|
| Projeto `agents-credentials` / projetos `<app>-dev` | `imports.agents_credentials_project_id`, `imports.app_infisical_project_ids` |
| Identity do agente + Universal Auth | `imports.agents.<agent>.infisical_identity_id` |
| Memberships nos projetos | automático (`adopt_existing = true`) |
| Pasta `/<agent>` | **não importável**: `imports.agents.<agent>.folder_exists = true` (o código deixa de gerenciar a pasta) |
| Segredos já gravados (`GIT_*`, `GH_APP_*`, `AWS_*`) | `imports.agents.<agent>.secrets` (exige o ID do `agents-credentials`) |
| Repos já selecionados na instalação da App | `infra/app-installations/` com `-var adopt_existing=true` (uma vez) |
| Role `agents-dev` + policy + attachment | `imports.aws_base = true` |
| Usuário IAM + inline policy | `imports.agents.<agent>.iam_user = true` |
| Role `agents_dev` do Neon | `imports.neon_roles = ["<app>"]` |

Não dá para importar valores que não podem ser lidos de volta: o **client secret** do Universal Auth e a **access key** AWS. O `apply` cria novos, grava no Infisical e o `sync-multica.sh` atualiza o Multica. Depois disso, revogue à mão o client secret antigo (Infisical → identity → Universal Auth) e apague a access key antiga.

**Rode `tofu plan` e leia antes de aplicar.** Qualquer `destroy`/`replace` de recurso adotado indica divergência entre o tfvars e o que existe. Corrija o tfvars em vez de aplicar. Os projetos Infisical têm `prevent_destroy` e `has_delete_protection`.

## 3. Operação do dia a dia

### 3.1 Onboarding de um agente

1. Crie a GitHub App `<org>-<agent>` (seção 3.4) e instale na org com **um** repo qualquer. Anote o Installation ID.
2. Adicione uma entrada no mapa `agents` do `<org>.tfvars`:
   ```hcl
   agents = {
     pe-backend = {
       display_name = "PE Backend"                # nome exato no Multica
       apps         = ["billing"]                 # projetos <app>-dev em que entra
       aws          = true                        # usuário IAM + chaves AWS_*
       railway      = ["billing/api"]             # vira RAILWAY_TOKEN_BILLING_API (<app>/<chave em apps.*.railway>)
       github = {
         installation_id = 12345678
         repos           = ["billing", "billing-web"]
         # app_slug    = "<org>-pe-backend"       # padrão
         # bot_user_id = 123                      # padrão: lido de "<app_slug>[bot]"
       }
       multica = { max_concurrent_tasks = 2, skills = ["<org>-conventions"] }
     }
   }
   ```
3. Abra o PR. O pipeline comenta o `plan`, o code owner aprova e o `apply` roda depois do merge (seção 6). Em seguida, o owner aplica `infra/app-installations/` localmente para instalar a App nos repos.
4. Cliques manuais da seção 3.4 para esse agente.
5. Se o agente ainda não existe no Multica: `scripts/multica-workspace.py bootstrap multica/<org>` (com o `.json`/`.md` dele) ou `sync-multica.sh --runtime-id <id>` (cria um agente vazio).
6. `scripts/sync-multica.sh --var-file infra/<org>.tfvars --only pe-backend [--railway]`.
7. Smoke test (runbook §9).

**Tokens do Railway:** cada entrada `<app>/<chave>` vira o segredo `RAILWAY_TOKEN_<APP>_<CHAVE>` em `/<agent>`, com caracteres não alfanuméricos trocados por `_` (`billing/api-server` → `RAILWAY_TOKEN_BILLING_API_SERVER`). Assim, o mesmo serviço em dois apps não colide. Se duas entradas resultarem no mesmo nome (`a-b/c` e `a/b-c`), a validação de `var.agents` recusa o `plan`. As instruções do agente devem usar o nome completo, exportando o token como `RAILWAY_TOKEN` só na hora do uso.

> **Migração:** a primeira versão deste PR gerava `RAILWAY_TOKEN_<CHAVE>`, sem o app, e o runbook OVER-7 usava `RAILWAY_TOKEN_<PROJECT>`. Nenhum token foi criado com esses nomes (a Overlens ainda não tem `apps`). Se algum existir à mão, rode `railway-tokens.sh` para criar os nomes novos, atualize as instruções dos agentes, apague os segredos antigos em `/<agent>` e os tokens antigos no Railway.

O `apply` cria: identity `agent-<agent>` com Universal Auth e client secret; membership em `agents-credentials` e nos `<app>-dev`; a pasta `/<agent>`; `GH_APP_ID`, `GH_APP_INSTALLATION_ID` e `GIT_AUTHOR_*`/`GIT_COMMITTER_*`; e, com `aws = true`, o usuário `/agents/agent-<agent>`, a inline policy `assume-agents-dev`, a access key e `AWS_*` em `/<agent>`.

### 3.2 Offboarding

1. Remova a entrada do mapa `agents` (e de `imports.agents`, se houver).
2. `tofu plan` (confira: só recursos de `module.agent["<agent>"]` saem) e `tofu apply`. Isso apaga a identity (o agente perde acesso a **todos** os segredos na hora), as memberships, a pasta `/<agent>` com tudo dentro (`force_delete`), o usuário IAM e a access key. Depois, o `apply` local de `infra/app-installations/` tira os repos da instalação da App.
3. Fora do Tofu, na ordem do runbook §11:
   - **Multica:** `multica agent env set <id> --custom-env '{}'`, `multica agent update <id> --mcp-config null`, `multica agent archive <id>`.
   - **GitHub:** desinstale ou apague a App e revogue a private key.
   - **Notion:** apague a integração.
   - **Railway:** apague os tokens `agent-<agent>`.
   - **AWS:** para cortar sessões já assumidas antes de 1 h, use "Revoke active sessions" no role `agents-dev` (afeta todos os agentes, que só precisam reassumir).
   - Se a pasta era `folder_exists = true`, apague `/<agent>` à mão.
4. Registre na issue de offboarding o que foi revogado e quando.

### 3.3 Rotação

| Credencial | Como |
|---|---|
| Client secret do Infisical | `tofu apply -replace='module.agent["<agent>"].infisical_identity_universal_auth_client_secret.this'` e depois `sync-multica.sh --only <agent>` |
| Access key AWS | `tofu apply -replace='module.agent["<agent>"].aws_iam_access_key.this[0]'` (a nova já vai para o Infisical) |
| Senha `agents_dev` do Neon | resete no console do Neon e rode `tofu apply` (o `DATABASE_URL` é relido) |
| Token Railway | `scripts/railway-tokens.sh --var-file infra/<org>.tfvars --rotate` e apague o token antigo no Railway |
| Private key da App / token do Notion | manual (seção 3.4), atualizando `GH_APP_PRIVATE_KEY` / `NOTION_TOKEN` no Infisical |

Como tudo, exceto a machine identity, vive no Infisical, só a rotação do client secret mexe no Multica.

### 3.4 Passos manuais (sem provider ou API)

- **GitHub App** por agente (runbook OVER-5): crie `<org>-<agent>` com as permissões do runbook, gere a private key e grave em `/<agent>` como `GH_APP_PRIVATE_KEY`. Apague o `.pem` local. Os repos da instalação passam a ser de `infra/app-installations/`: não os edite pela UI.
- **Notion:** crie a integração interna `<Org> · <AgentName>`, compartilhe só com o teamspace e grave o token em `/<agent>` como `NOTION_TOKEN`.
- **Vercel ← Infisical:** o provider Infisical 0.20.x **não tem** recurso de sync para Vercel (só `infisical_secret_sync_*` para outros destinos). Para cada linha de `tofu output vercel_sync_checklist`: Infisical → projeto `<app>-dev` → Integrations → Secret Syncs → **Vercel**, env `dev`, path `/`, destino o projeto Vercel, **somente Preview e Development**. Não use o espelhamento por `vercel_project_environment_variable` no Tofu: ele só sincroniza no `apply`, e os agentes alteram variáveis no Infisical sem rodar `apply`.

## 4. Isolamento entre agentes no `agents-credentials`

Com `agents_credentials.isolate = false` (padrão, e o caso da Overlens), todo agente é `member` do projeto e lê `/<outro-agente>`. Com `isolate = true`, o agente vira `no-access` e recebe um *identity-specific privilege* que só lê `/<agent>/**`. Esse recurso exige uma edição do Infisical com *additional privileges*. Ligue só depois de validar numa identity de teste. A alternativa sem esse recurso é um projeto `agents-credentials-<agent>` por agente (não implementada).

## 5. Verificação local e CI

```bash
scripts/ci.sh
```

O `scripts/ci.sh` roda tudo o que o PR checa, igual na máquina local e no CI: `tofu fmt -check`, `init -backend=false` + `validate` e `tofu test` (providers mockados) nos dois root modules (`infra/` e `infra/app-installations/`), o check de segurança de `infra/` (seção 6.3) com seu teste offline, `tflint` (obrigatório quando `CI=true`), `shellcheck`, o teste offline do `railway-tokens.sh` (tokens nunca aparecem em argv nem na saída) e o `unittest` da reconciliação de crons do bootstrap. O workflow `.github/workflows/validate.yml` só chama esse script, com OpenTofu 1.9.4 e 1.13.2, e não roda em PR draft.

O `tofu test` não usa backend nem criptografia e não toca em conta nenhuma. Os blocos `import` não rodam sob `tofu test`. Eles foram conferidos com `tofu console -var-file=overlens.tfvars` numa cópia sem backend.

## 6. Pipeline

### 6.1 Fluxo

1. Um agente abre um PR. O `validate.yml` roda os `Static checks` (OpenTofu 1.9.4 e 1.13.2).
2. Se o PR muda `infra/` (fora de `app-installations/`), o job `plan` do `plan.yml` espera a aprovação do Rafael no environment `infra-plan`. Depois disso ele roda o check de segurança **da branch base**, faz `tofu plan`, comenta o resumo e o plano completo no PR e salva o plano cifrado como artefato `tfplan-pr<N>`. Um PR que não toca `infra/` pula o job, e o GitHub conta isso como check verde.
3. O Rafael aprova o PR (code owner de `infra/`) e o Tech Lead faz o merge.
4. O `apply.yml` (push na `main`, environment `infra`) baixa o plano revisado e aplica **esse plano**, sem re-plan. Ele falha se:
   - o `infra/` da `main` diferir do que foi planejado (outro PR entrou antes);
   - o state mudou desde o plano (`Saved plan is stale`, checado pelo OpenTofu);
   - não houver plano para o último commit do PR, ou o artefato não vier do `plan.yml`.

   Nos três casos, abra um PR novo (pode ser só um comentário no tfvars) para gerar um plano atualizado e revisado.

| | `plan` (PR) | `apply` (`main`) |
|---|---|---|
| Environment | `infra-plan`, com reviewer obrigatório (Rafael) | `infra`, deployment só da branch `main` |
| AWS (OIDC) | `multica-config-plan`: leitura de IAM e do state, `-lock=false` | `multica-config-apply`: IAM só em `user/agents/agent-*`, `role/agents-dev` e `policy/agents-dev-access`, além do state |
| Infisical | identity admin do pipeline (OIDC Auth) | a mesma |
| GitHub | token da App `overlens-infra-admin` com `administration: read` | o mesmo, com `administration: write` |
| `GITHUB_TOKEN` do job | `contents: read`, `id-token: write`, `pull-requests: write` | `contents: read`, `id-token: write`, `actions: read`, `pull-requests: read` |

As policies dos roles estão em [`scripts/pipeline/`](../scripts/pipeline/), com os valores da Overlens. Os dois roles só enxergam `agents/*` no bucket: o state de `app-installations/` fica fora do alcance do pipeline.

### 6.2 Por que `app-installations/` é um root module à parte

`github_app_installation_repository` só funciona com token de **usuário** owner. Pela decisão de 26/10 (opção b), esse recurso fica fora do pipeline. Havia duas formas de fazer isso, e a escolhida foi o root module separado `infra/app-installations/`, com state próprio (`app-installations/terraform.tfstate`, mesmo bucket e mesma chave KMS):

- Com `-target`/`-exclude`, a flag precisa estar em todo `plan`, `apply` e na auditoria. Uma flag esquecida faz o pipeline tentar mexer nas instalações com token de App, e o próprio OpenTofu desaconselha `-target` como rotina.
- Com os recursos no state principal, cada mudança em `agents.<agent>.github.repos` deixaria diferença pendente no `plan` do pipeline até o apply local, e a auditoria nunca mostraria "No changes".
- Com state separado, os roles do pipeline nem têm acesso ao state das instalações, e o apply local só precisa de `GITHUB_TOKEN` de usuário e da chave KMS, sem Infisical nem Neon.
- Os dois módulos leem o mesmo `<org>.tfvars`, então `agents.<agent>.github.repos` continua com uma única fonte. O custo é um warning `Value for undeclared variable` no módulo das instalações.

A migração é segura. O `removed.tf` da stack principal só **esquece** os recursos, sem desinstalar nada, e o `app-installations/` os adota com `-var adopt_existing=true` (passo 7 do bootstrap).

### 6.3 Segurança do `plan` em PR

O `plan` executa código do PR e decripta o state, que contém segredos. Por isso:

- PRs de fork nunca chegam ao job com credenciais, e o GitHub também não entrega token OIDC a eles.
- Nenhuma credencial existe antes da aprovação do Rafael no environment `infra-plan`. Um PR que altera `.github/workflows/` roda **a versão do PR** do workflow, então confira o diff inteiro antes de aprovar o deployment. O environment `infra` só aceita a `main`, então um PR não consegue usá-lo.
- Antes de qualquer credencial, o job roda `scripts/check-infra-safety.sh` **da branch base** contra o código do PR. O check recusa:
  - `provisioner` (inclusive `local-exec`), `data "external"` e `data "http"`;
  - providers fora da allowlist (o lock file é lido com `-lockfile=readonly`);
  - módulos não locais ou fora de `infra/`;
  - `*.tf.json`, `.terraform/` versionado, `terraform.d/` e arquivos de tipo inesperado (injeção de binário de provider).

  Para mudar a allowlist, primeiro faça um PR só no script e faça o merge dele.
- As credenciais do `plan` são de leitura (AWS e GitHub). A exceção é a identity do Infisical: não existe papel de admin só leitura que cubra identities.
- O artefato do plano sai cifrado com a chave KMS do state (`plan { enforced = true }`).
- ⚠️ **O repo é público.** Os logs do Actions e o comentário do `plan` são públicos. Valores `sensitive` aparecem como `(sensitive value)`, mas nomes, IDs e ARNs aparecem como no tfvars. Tornar o repo privado é decisão do Rafael.

### 6.4 Bootstrap (Rafael, uma vez)

Faça na ordem. Nada daqui fica no WSL depois: as credenciais admin passam a existir só nos environments do GitHub.

1. **AWS: provider OIDC, roles e chave KMS**, com credencial admin numa shell temporária:
   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com
   for r in plan apply; do
     aws iam create-role --role-name "multica-config-$r" --max-session-duration 3600 \
       --assume-role-policy-document "file://scripts/pipeline/trust-$r.json"
     aws iam put-role-policy --role-name "multica-config-$r" --policy-name "multica-config-$r" \
       --policy-document "file://scripts/pipeline/policy-$r.json"
   done
   # A lista SUBSTITUI os usuários da chave: inclua o seu ARN de admin.
   scripts/bootstrap.sh --org overlens --region sa-east-1 \
     --admin-arn <seu-arn-admin> \
     --admin-arn arn:aws:iam::437341204924:role/multica-config-plan \
     --admin-arn arn:aws:iam::437341204924:role/multica-config-apply
   ```
   A trust policy aceita só `repo:overlens/multica-config:environment:infra-plan` (role de plan) e `...:environment:infra` (role de apply). Os roles precisam existir antes do `bootstrap.sh`, porque a KMS valida os principals.
2. **Infisical: identity admin do pipeline.** O self-hosted suporta OIDC Auth: em 26/10, `POST /api/v1/auth/oidc-auth/login` respondeu `OIDC auth method not found for identity`, e não 404 de rota. O provider 0.20.7 aceita OIDC por env (`INFISICAL_AUTH_METHOD=oidc`). Em Organization → Access Control → Identities:
   - crie `multica-config-pipeline`, com org role **Admin**;
   - em Auth Methods, adicione **OIDC Auth**:
     - Discovery URL e Issuer: `https://token.actions.githubusercontent.com`;
     - Subject: `repo:overlens/multica-config:environment:infra*` (se o campo não aceitar glob, crie uma identity por environment, cada uma com o seu `INFISICAL_IDENTITY_ID`);
     - Audiences: `https://secrets.overlens.com.br`;
     - Claims: `repository=overlens/multica-config`;
     - access token TTL de 1800 s e max TTL de 3600 s;
   - não deixe Universal Auth nessa identity;
   - se o OIDC Auth for recusado na criação (licença), use o fallback: Universal Auth com client secret de TTL ≤ 30 dias, os secrets `INFISICAL_UNIVERSAL_AUTH_CLIENT_*` e `INFISICAL_AUTH_METHOD=universal`. A rotação é: gerar um secret novo, atualizar os dois environments e revogar o antigo.
3. **GitHub App `overlens-infra-admin`** (org overlens, sem webhook):
   - permissões: Repository → **Administration: Read and write** e Metadata: Read (obrigatória), nada mais;
   - instale em **All repositories**, para que repos novos entrem no módulo `repos` da fase 2;
   - anote o **Client ID**, gere a private key, guarde-a só no secret (passo 4) e apague o `.pem`.
4. **Environments** (Settings → Environments do `multica-config`). Todos os valores ficam no environment, nunca no nível do repo ou da org:
   - `infra-plan`: Required reviewers = RafaelBraz; Deployment branches = sem restrição (runs de PR usam `refs/pull/*`).
   - `infra`: Deployment branches = **Selected branches → `main`**. Um reviewer é opcional, porque o PR já teve a aprovação do code owner.

   | Nome | Tipo | `infra-plan` | `infra` |
   |---|---|---|---|
   | `AWS_ROLE_ARN` | variable | `arn:aws:iam::437341204924:role/multica-config-plan` | `arn:aws:iam::437341204924:role/multica-config-apply` |
   | `AWS_REGION` / `AWS_ACCOUNT_ID` | variable | `sa-east-1` / `437341204924` | igual |
   | `INFISICAL_IDENTITY_ID` | variable | ID da identity do passo 2 | igual |
   | `INFISICAL_OIDC_AUDIENCE` | variable | `https://secrets.overlens.com.br` | igual |
   | `INFRA_ADMIN_APP_CLIENT_ID` | variable | Client ID da App | igual |
   | `INFRA_ADMIN_APP_PRIVATE_KEY` | secret | private key da App | igual |
   | `INFISICAL_AUTH_METHOD` | variable | só no fallback: `universal` | igual |
   | `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` / `_SECRET` | secret | só no fallback | igual |
   | `NEON_API_KEY` | secret | só quando algum app tiver `neon` | igual |

   Em Settings → Actions, deixe "Require approval for all external contributors" ligado (o repo é público).
5. **Workflows:** commite `.github/workflows/plan.yml` e `apply.yml` (anexos da OVER-15). O `CODEOWNERS` já está na raiz do repo.
6. **Rulesets.** O ruleset de org `main-protection` (id `25838050`) já é o piso de todos os repos: PR obrigatório, sem force push nem deleção, bypass vazio. **Não** ponha checks obrigatórios nele, porque um check que não roda num repo trava o merge ali. Falta:
   - **Review de code owner obrigatório**, na org (não tem efeito em repo sem `CODEOWNERS`) ou num ruleset de repo, com "Dismiss stale approvals" e "Require approval of the most recent reviewable push". A contagem de aprovações fica em 0, porque o Tech Lead faz merge do que não tem code owner.
   - Um **ruleset de repo** no `multica-config`, na branch `main`, com os status checks obrigatórios `Static checks (OpenTofu 1.9.4)`, `Static checks (OpenTofu 1.13.2)` e `plan` (fonte: GitHub Actions) e com **Require branches to be up to date**, que força um plano novo quando a `main` anda.

   As regras de org e de repo se somam. A fase 2 leva os dois para o módulo `repos`; até lá, crie-os pela UI.
7. **Migrar as instalações** (depois do primeiro `apply` do pipeline, que mostra os repos como `forget`):
   ```bash
   cd infra/app-installations
   export GITHUB_TOKEN="$(gh auth token)"   # usuário owner, só nesta shell
   tofu init -var-file=../overlens.tfvars
   tofu plan -var-file=../overlens.tfvars -var adopt_existing=true   # esperado: 12 to import, nada mais
   tofu apply -var-file=../overlens.tfvars -var adopt_existing=true
   ```
8. **Prova:** abra um PR trivial no `overlens.tfvars` (um comentário). Ele precisa gerar o comentário do `plan` sem mudanças, e o merge precisa aplicar com "No changes".

### 6.5 Operação

- **Repos de um agente** (`agents.<agent>.github.repos`): o PR segue o fluxo normal. A stack principal não muda; depois do merge, o Rafael roda `tofu apply -var-file=../overlens.tfvars` em `infra/app-installations/`.
- **Apply falhou** por plano stale ou por divergência de `infra/`: abra um PR novo para gerar outro plano. Não rode `tofu` localmente para "destravar".
- **Rotação:** a private key da App (gerar uma nova, atualizar o secret nos dois environments, apagar a antiga) e o client secret do fallback do Infisical. AWS e Infisical OIDC não têm segredo fixo.

## 7. Pendências ⚠️ para o primeiro `plan`

1. Preencher os `TODO` do `overlens.tfvars`: ID da conta AWS, região, org ID do Infisical, IDs das identities e Installation IDs.
2. Org role das identities existentes (`agent_org_role`): o exemplo usa `member`. Se o `plan` mostrar mudança, ajuste.
3. Criar uma pasta que já existe falha ou é idempotente na versão self-hosted? Por isso as pastas existentes estão com `folder_exists = true`.
4. Lookup do bot por `data "github_user"` com `<slug>[bot]`: se falhar, informe `bot_user_id`.
5. Nomes de ações do `permissions_v2` (`describeSecret`, `readValue`) na versão self-hosted, se ligar `isolate`.
6. `railway-tokens.sh`: mutation `projectTokenCreate` da API GraphQL do Railway, não testada contra conta real.
7. Ações de CloudFront com `aws:ResourceTag` (Policy Simulator), herdado do runbook §6.
