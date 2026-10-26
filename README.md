# multica-config

Configuração operacional do modelo humano + agentes no Multica.

| Caminho | O quê |
|---|---|
| [`infra/`](infra/README.md) | Onboarding/offboarding de agentes como código (OpenTofu): AWS, Infisical, Neon, GitHub App. **Comece pelo `infra/README.md`.** |
| `scripts/bootstrap.sh` | Bucket de state e chave KMS da org (uma vez) |
| `scripts/sync-multica.sh` | Leva os outputs do Tofu para os agentes no Multica |
| `scripts/railway-tokens.sh` | Tokens do Railway por agente (sem provider) |
| `scripts/multica-workspace.py` | Exporta/recria agentes, skills e autopilots de um workspace |
| `multica/overlens/` | Export do workspace Overlens (template para outras orgs) |
| `configure-agent.sh` | Env (machine identity do Infisical) e MCP do Notion de um agente |
