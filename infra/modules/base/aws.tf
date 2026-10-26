# Shared role assumed by every agent user (runbook §6.1). Each agent has its
# own IAM user; the trust policy forces the session name to be the user name,
# so CloudTrail shows `<role>/<user>` for every action.

locals {
  agent_users_arn    = "arn:aws:iam::${var.aws_account_id}:user${var.aws.user_path}${var.aws.user_prefix}*"
  distributions_arn  = "arn:aws:cloudfront::${var.aws_account_id}:distribution/*"
  dev_bucket_arns    = ["arn:aws:s3:::${var.aws.dev_bucket_pattern}", "arn:aws:s3:::${var.aws.dev_bucket_pattern}/*"]
  denied_bucket_arns = flatten([for p in var.aws.denied_bucket_patterns : ["arn:aws:s3:::${p}", "arn:aws:s3:::${p}/*"]])
  # The admin-only state bucket is outside the dev pattern already; the
  # explicit Deny keeps it out even if the pattern is ever widened.
  state_bucket_arns = ["arn:aws:s3:::${var.org}-terraform-state", "arn:aws:s3:::${var.org}-terraform-state/*"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "AllowAgentUsersWithOwnSessionName"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [local.agent_users_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:RoleSessionName"
      values   = ["$${aws:username}"]
    }
  }
}

data "aws_iam_policy_document" "access" {
  statement {
    sid       = "ListBuckets"
    effect    = "Allow"
    actions   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
    resources = ["*"]
  }

  statement {
    sid    = "DevBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket", "s3:GetBucketCors", "s3:PutBucketCors",
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectTagging", "s3:PutObjectTagging",
    ]
    resources = local.dev_bucket_arns
  }

  statement {
    sid       = "CloudFrontRead"
    effect    = "Allow"
    actions   = ["cloudfront:ListDistributions", "cloudfront:ListTagsForResource"]
    resources = ["*"]
  }

  statement {
    sid    = "CloudFrontDevByTag"
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution",
      "cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations",
    ]
    resources = [local.distributions_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.aws.cloudfront_dev_tag.key}"
      values   = [var.aws.cloudfront_dev_tag.value]
    }
  }

  statement {
    sid       = "DenyProtectedBuckets"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = concat(local.denied_bucket_arns, local.state_bucket_arns)
  }

  statement {
    sid    = "DenyNonDevDistributions"
    effect = "Deny"
    actions = [
      "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
      "cloudfront:CreateInvalidation", "cloudfront:GetDistributionConfig",
    ]
    resources = [local.distributions_arn]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/${var.aws.cloudfront_dev_tag.key}"
      values   = [var.aws.cloudfront_dev_tag.value]
    }
  }

  # Stops an agent from tagging a prod distribution as dev to gain access.
  statement {
    sid       = "DenyRetagging"
    effect    = "Deny"
    actions   = ["cloudfront:TagResource", "cloudfront:UntagResource", "s3:PutBucketTagging"]
    resources = ["*"]
  }

  # No identity changes and no role chaining. The state KMS key is guarded by
  # its own key policy (scripts/bootstrap.sh), which only admits the admin.
  statement {
    sid       = "DenyIdentityAndBilling"
    effect    = "Deny"
    actions   = ["iam:*", "organizations:*", "account:*", "sts:AssumeRole"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "access" {
  name        = var.aws.policy_name
  description = "Dev-only access for AI agents (assumed through ${var.aws.role_name})."
  policy      = data.aws_iam_policy_document.access.json
}

resource "aws_iam_role" "agents" {
  name                 = var.aws.role_name
  description          = "Shared role for AI agents; session name must equal the agent user name."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.aws.max_session_duration
  # The same policy is the boundary, so nothing attached later can widen it.
  permissions_boundary = aws_iam_policy.access.arn
}

resource "aws_iam_role_policy_attachment" "access" {
  role       = aws_iam_role.agents.name
  policy_arn = aws_iam_policy.access.arn
}
