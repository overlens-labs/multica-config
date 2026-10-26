# Installation repos moved to infra/app-installations/ (own state, applied
# locally by an org owner: the pipeline's App token can't manage them). The
# main stack only forgets them; nothing is uninstalled. Once the first apply
# with this block is done, it is a no-op and can stay.
#
# No `lifecycle { destroy = false }`: OpenTofu 1.9 doesn't accept it and its
# `removed` always means "forget". 1.13 warns about the missing lifecycle.
removed {
  from = module.agent.github_app_installation_repository.this
}
