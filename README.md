# multica-config

Configuração operacional do modelo humano + agentes no Multica.

| Caminho | O quê |
|---|---|
| [`infra/`](infra/README.md) | Onboarding/offboarding de agentes como código (OpenTofu): AWS, Infisical, Neon, GitHub App. **Comece pelo `infra/README.md`.** |
| `infra/app-installations/` | Repos na instalação da GitHub App de cada agente (state próprio, `apply` local do owner) |
| Pipeline (`plan.yml`/`apply.yml`) | Mudança em `infra/` só por PR: `plan` comentado no PR, `apply` do mesmo plano depois do merge ([`infra/README.md` §6](infra/README.md#6-pipeline)) |
| `scripts/bootstrap.sh` | Bucket de state e chave KMS da org (uma vez) |
| `scripts/sync-multica.sh` | Leva os outputs do Tofu para os agentes no Multica |
| `scripts/check-infra-safety.sh` | Bloqueia provisioners, `data "external"`/`"http"` e providers/módulos fora da allowlist em `infra/` |
| `scripts/pipeline/` | Trust e permission policies dos roles OIDC do pipeline |
| `CODEOWNERS` | `infra/`, `scripts/`, `.github/` → aprovação do Rafael |
| `scripts/railway-tokens.sh` | Tokens do Railway por agente (sem provider) |
| `scripts/multica-workspace.py` | Exporta/recria agentes, skills e autopilots de um workspace |
| `multica/overlens/` | Export do workspace Overlens (template para outras orgs) |
| `configure-agent.sh` | Env (machine identity do Infisical) e MCP do Notion de um agente |
