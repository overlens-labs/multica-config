# Onboarding de agentes como código

Este diretório transforma em código o runbook de onboarding de agentes (OVER-7), seguindo a decisão registrada na OVER-9. Ele serve para qualquer organização: org, domínio, região e IDs entram por `<org>.tfvars`. O arquivo [`overlens.tfvars`](overlens.tfvars) é o exemplo da Overlens e não contém segredo.

| O quê | Onde |
|---|---|
| Bucket de state + chave KMS (uma vez por org) | `scripts/bootstrap.sh` |
| AWS, Infisical, Neon, instalação da GitHub App | `infra/` (OpenTofu) |
| Agente no Multica (env, MCP, skill, concorrência) | `scripts/sync-multica.sh` → `configure-agent.sh` |
| Tokens do Railway | `scripts/railway-tokens.sh` (o provider não cobre) |
| Agentes, skills e autopilots de um workspace novo | `scripts/multica-workspace.py` + `multica/<org>/` |
| Criar a GitHub App, integração do Notion e sync Vercel ← Infisical | cliques manuais (seção 3.4) |

**Regras que o código garante:**
- Só o admin humano roda `plan`/`apply`, com credencial admin. Os agentes escrevem e revisam este código, mas nunca aplicam.
- Credenciais geradas (client secret do Infisical, access key AWS, senha do Neon) vão direto para o Infisical. Nenhum output não-`sensitive` carrega segredo.
- O state fica no bucket `<org>-terraform-state`, com lock nativo (`use_lockfile`) e **criptografia nativa do OpenTofu** com a chave KMS `alias/<org>-terraform-state` (`enforced = true`: nunca grava state ou plan em claro). O state contém segredos (access keys, client secrets, senha do Neon), e é por isso que tanto a chave quanto o bucket ficam restritos ao admin.

## 1. Pré-requisitos (máquina do admin)

- OpenTofu ≥ 1.9 (testado com 1.9.4 e 1.13.2), AWS CLI v2, `jq`, `python3`, CLI do Infisical, CLI do `multica` (logado no workspace certo), `notion-mcp-server` no `PATH` (o `configure-agent.sh` exige).
- Credenciais admin **no ambiente**, nunca em arquivo versionado:

| Variável | Para quê |
|---|---|
| `AWS_PROFILE` (ou `AWS_ACCESS_KEY_ID`/...) | conta AWS da org; o provider recusa outra conta (`allowed_account_ids`) |
| `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` / `_SECRET` | machine identity **admin** do Infisical (org admin) |
| `NEON_API_KEY` | só se algum app tiver `neon` |
| `GITHUB_TOKEN` | token de **usuário** owner da org. Adicionar repos a uma instalação não funciona com token de App |
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
tofu apply tfplan
```

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
| Repos já selecionados na instalação da App | automático para agentes listados em `imports.agents` |
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
3. `tofu plan -var-file=<org>.tfvars -out=tfplan && tofu apply tfplan`.
4. Cliques manuais da seção 3.4 para esse agente.
5. Se o agente ainda não existe no Multica: `scripts/multica-workspace.py bootstrap multica/<org>` (com o `.json`/`.md` dele) ou `sync-multica.sh --runtime-id <id>` (cria um agente vazio).
6. `scripts/sync-multica.sh --var-file infra/<org>.tfvars --only pe-backend [--railway]`.
7. Smoke test (runbook §9).

**Tokens do Railway:** cada entrada `<app>/<chave>` vira o segredo `RAILWAY_TOKEN_<APP>_<CHAVE>` em `/<agent>`, com caracteres não alfanuméricos trocados por `_` (`billing/api-server` → `RAILWAY_TOKEN_BILLING_API_SERVER`). Assim, o mesmo serviço em dois apps não colide. Se duas entradas resultarem no mesmo nome (`a-b/c` e `a/b-c`), a validação de `var.agents` recusa o `plan`. As instruções do agente devem usar o nome completo, exportando o token como `RAILWAY_TOKEN` só na hora do uso.

> **Migração:** a primeira versão deste PR gerava `RAILWAY_TOKEN_<CHAVE>`, sem o app, e o runbook OVER-7 usava `RAILWAY_TOKEN_<PROJECT>`. Nenhum token foi criado com esses nomes (a Overlens ainda não tem `apps`). Se algum existir à mão, rode `railway-tokens.sh` para criar os nomes novos, atualize as instruções dos agentes, apague os segredos antigos em `/<agent>` e os tokens antigos no Railway.

O `apply` cria: identity `agent-<agent>` com Universal Auth e client secret; membership em `agents-credentials` e nos `<app>-dev`; a pasta `/<agent>`; `GH_APP_ID`, `GH_APP_INSTALLATION_ID` e `GIT_AUTHOR_*`/`GIT_COMMITTER_*`; os repos na instalação da App; e, com `aws = true`, o usuário `/agents/agent-<agent>`, a inline policy `assume-agents-dev`, a access key e `AWS_*` em `/<agent>`.

### 3.2 Offboarding

1. Remova a entrada do mapa `agents` (e de `imports.agents`, se houver).
2. `tofu plan` (confira: só recursos de `module.agent["<agent>"]` saem) e `tofu apply`. Isso apaga a identity (o agente perde acesso a **todos** os segredos na hora), as memberships, a pasta `/<agent>` com tudo dentro (`force_delete`), o usuário IAM e a access key, e tira os repos da instalação da App.
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

- **GitHub App** por agente (runbook OVER-5): crie `<org>-<agent>` com as permissões do runbook, gere a private key e grave em `/<agent>` como `GH_APP_PRIVATE_KEY`. Apague o `.pem` local. Os repos da instalação passam a ser do Tofu: não os edite pela UI.
- **Notion:** crie a integração interna `<Org> · <AgentName>`, compartilhe só com o teamspace e grave o token em `/<agent>` como `NOTION_TOKEN`.
- **Vercel ← Infisical:** o provider Infisical 0.20.x **não tem** recurso de sync para Vercel (só `infisical_secret_sync_*` para outros destinos). Para cada linha de `tofu output vercel_sync_checklist`: Infisical → projeto `<app>-dev` → Integrations → Secret Syncs → **Vercel**, env `dev`, path `/`, destino o projeto Vercel, **somente Preview e Development**. Não use o espelhamento por `vercel_project_environment_variable` no Tofu: ele só sincroniza no `apply`, e os agentes alteram variáveis no Infisical sem rodar `apply`.

## 4. Isolamento entre agentes no `agents-credentials`

Com `agents_credentials.isolate = false` (padrão, e o caso da Overlens), todo agente é `member` do projeto e lê `/<outro-agente>`. Com `isolate = true`, o agente vira `no-access` e recebe um *identity-specific privilege* que só lê `/<agent>/**`. Esse recurso exige uma edição do Infisical com *additional privileges*. Ligue só depois de validar numa identity de teste. A alternativa sem esse recurso é um projeto `agents-credentials-<agent>` por agente (não implementada).

## 5. Verificação local e CI

```bash
scripts/ci.sh
```

O `scripts/ci.sh` roda tudo o que o PR checa, igual na máquina local e no CI: `tofu fmt -check`, `init -backend=false` + `validate`, `tofu test` (providers mockados), `tflint` (obrigatório quando `CI=true`), `shellcheck`, o teste offline do `railway-tokens.sh` (tokens nunca aparecem em argv nem na saída) e o `unittest` da reconciliação de crons do bootstrap. O workflow `.github/workflows/validate.yml` só chama esse script, com OpenTofu 1.9.4 e 1.13.2, e não roda em PR draft.

O `tofu test` não usa backend nem criptografia e não toca em conta nenhuma. Os blocos `import` não rodam sob `tofu test`. Eles foram conferidos com `tofu console -var-file=overlens.tfvars` numa cópia sem backend.

## 6. Pendências ⚠️ para o primeiro `plan`

1. Preencher os `TODO` do `overlens.tfvars`: ID da conta AWS, região, org ID do Infisical, IDs das identities e Installation IDs.
2. Org role das identities existentes (`agent_org_role`): o exemplo usa `member`. Se o `plan` mostrar mudança, ajuste.
3. Criar uma pasta que já existe falha ou é idempotente na versão self-hosted? Por isso as pastas existentes estão com `folder_exists = true`.
4. Lookup do bot por `data "github_user"` com `<slug>[bot]`: se falhar, informe `bot_user_id`.
5. Nomes de ações do `permissions_v2` (`describeSecret`, `readValue`) na versão self-hosted, se ligar `isolate`.
6. `railway-tokens.sh`: mutation `projectTokenCreate` da API GraphQL do Railway, não testada contra conta real.
7. Ações de CloudFront com `aws:ResourceTag` (Policy Simulator), herdado do runbook §6.
