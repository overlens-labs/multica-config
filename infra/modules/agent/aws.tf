# Per-agent IAM user whose only permission is assuming the shared role
# (runbook §6.2). The user path is what the role's trust policy matches.

resource "aws_iam_user" "this" {
  count = var.aws == null ? 0 : 1

  name = "${var.aws.user_prefix}${var.slug}"
  path = var.aws.user_path
}

data "aws_iam_policy_document" "assume" {
  count = var.aws == null ? 0 : 1

  statement {
    sid       = "AssumeAgentsDevOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [var.aws.role_arn]
  }
}

resource "aws_iam_user_policy" "assume" {
  count = var.aws == null ? 0 : 1

  name   = "assume-${var.aws.role_name}"
  user   = aws_iam_user.this[0].name
  policy = data.aws_iam_policy_document.assume[0].json
}

# Rotation: tofu apply -replace='module.agent["<agent>"].aws_iam_access_key.this[0]'
# (the new key is written to Infisical in the same apply).
resource "aws_iam_access_key" "this" {
  count = var.aws == null ? 0 : 1

  user = aws_iam_user.this[0].name
}
