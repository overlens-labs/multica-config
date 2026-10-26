#!/usr/bin/env bash
# Creates, idempotently, what the OpenTofu backend needs before the first
# `tofu init`: the S3 state bucket `<org>-terraform-state` (versioned, public
# access blocked, SSE-KMS, TLS only) and the KMS key `alias/<org>-terraform-state`
# used both by the bucket and by OpenTofu's native state encryption.
#
# Run once per org, by the admin, with admin AWS credentials (AWS_PROFILE...).
# Re-running only fills in whatever is missing; it never deletes anything.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") --org <org> --region <aws-region> [--admin-arn <arn>]... [--dry-run]

  --org        org slug; bucket "<org>-terraform-state", alias "alias/<org>-terraform-state"
  --region     AWS region of the bucket and the key
  --admin-arn  IAM principal allowed to use the key (repeatable). Default: the
               caller's identity (an assumed-role session is mapped to its role).
  --dry-run    print what would be created, change nothing
USAGE
  exit "${1:-1}"
}

ORG=""
REGION=""
ADMIN_ARNS=()
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --admin-arn) ADMIN_ARNS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$ORG" && -n "$REGION" ]] || usage
[[ "$ORG" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || { echo "--org must be a lowercase slug" >&2; exit 1; }
for bin in aws jq; do
  command -v "$bin" >/dev/null || { echo "Required command not found: $bin" >&2; exit 1; }
done

BUCKET="${ORG}-terraform-state"
ALIAS="alias/${ORG}-terraform-state"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

log() { echo "[$(date '+%F %T')] $*"; }
run() {
  if (( DRY_RUN )); then echo "  (dry-run) $*"; else "$@"; fi
}

caller="$(aws sts get-caller-identity --output json)"
ACCOUNT_ID="$(jq -r .Account <<<"$caller")"
if (( ${#ADMIN_ARNS[@]} == 0 )); then
  arn="$(jq -r .Arn <<<"$caller")"
  # arn:aws:sts::<acct>:assumed-role/<role>/<session> -> arn:aws:iam::<acct>:role/<role>
  # (SSO roles keep their path in IAM; pass --admin-arn explicitly in that case.)
  if [[ "$arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/ ]]; then
    arn="arn:aws:iam::${BASH_REMATCH[1]}:role/${BASH_REMATCH[2]}"
  fi
  ADMIN_ARNS=("$arn")
fi
log "Account $ACCOUNT_ID, region $REGION, key users: ${ADMIN_ARNS[*]}"

# --- KMS key ----------------------------------------------------------------
# The account root keeps key *administration* (so the key can never become
# unmanageable) but not usage; only the admin principals can encrypt/decrypt.
# Agents' users and the agents-dev role therefore can't use it.
key_policy() {
  jq -n --arg acct "$ACCOUNT_ID" --argjson admins "$(printf '%s\n' "${ADMIN_ARNS[@]}" | jq -R . | jq -s .)" '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "AccountAdministersKey",
        Effect: "Allow",
        Principal: { AWS: "arn:aws:iam::\($acct):root" },
        Action: [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*",
          "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:TagResource",
          "kms:UntagResource", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"
        ],
        Resource: "*"
      },
      {
        Sid: "AdminsUseKey",
        Effect: "Allow",
        Principal: { AWS: $admins },
        Action: ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"],
        Resource: "*"
      }
    ]
  }'
}

KEY_ID="$(aws kms describe-key --key-id "$ALIAS" --query KeyMetadata.KeyId --output text 2>/dev/null || true)"
if [[ -z "$KEY_ID" || "$KEY_ID" == "None" ]]; then
  log "Creating KMS key $ALIAS"
  if (( DRY_RUN )); then
    echo "  (dry-run) aws kms create-key + create-alias $ALIAS + enable-key-rotation"
    KEY_ID="<new-key-id>"
  else
    KEY_ID="$(aws kms create-key \
      --description "OpenTofu state for ${ORG} (bucket ${BUCKET})" \
      --policy "$(key_policy)" \
      --tags TagKey=managed-by,TagValue=agent-onboarding-bootstrap \
      --query KeyMetadata.KeyId --output text)"
    aws kms create-alias --alias-name "$ALIAS" --target-key-id "$KEY_ID"
  fi
else
  log "KMS key $ALIAS exists ($KEY_ID); refreshing its policy"
  run aws kms put-key-policy --key-id "$KEY_ID" --policy-name default --policy "$(key_policy)"
fi
run aws kms enable-key-rotation --key-id "$KEY_ID"
KEY_ARN="arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/${KEY_ID}"

# --- S3 bucket ----------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" 2>/dev/null; then
  log "Bucket $BUCKET exists; enforcing its settings"
else
  log "Creating bucket $BUCKET"
  if [[ "$REGION" == "us-east-1" ]]; then
    run aws s3api create-bucket --bucket "$BUCKET" --object-ownership BucketOwnerEnforced
  else
    run aws s3api create-bucket --bucket "$BUCKET" --object-ownership BucketOwnerEnforced \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

run aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
run aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
run aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration "$(jq -cn --arg k "$KEY_ARN" '{
  Rules: [{ ApplyServerSideEncryptionByDefault: { SSEAlgorithm: "aws:kms", KMSMasterKeyID: $k }, BucketKeyEnabled: true }]
}')"
run aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(jq -cn --arg b "$BUCKET" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "DenyInsecureTransport",
    Effect: "Deny",
    Principal: "*",
    Action: "s3:*",
    Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"],
    Condition: { Bool: { "aws:SecureTransport": "false" } }
  }]
}')"
run aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=managed-by,Value=agent-onboarding-bootstrap}]'

log "Done. Backend: bucket=$BUCKET region=$REGION; state key: $ALIAS"
log "Next: cd infra && tofu init -var-file=<org>.tfvars"
