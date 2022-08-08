#!/bin/bash
set -euo pipefail

# global variables
domain_name="${1}"
repository_name="${2:-}"
github_org="${3:-}"
stack_prefix="$(echo ${domain_name} | tr '.' '-')"

if [ -z "${domain_name}" ]; then
    echo "invalid usage"
    echo "$0 <domain_name> <repository_name> <github_org>"
    exit 1
fi

function get_stack_value() {
    local stack_name="$1"
    local output_key="$2"
    local region="${3:-ap-southeast-2}"

    aws cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue" \
        --region "${region}" \
        --output text
}

function get_function_version_arn() {
    local stack_name="$1"
    local region="$2"

    local arn="$(get_stack_value ${stack_name} LambdaFunctionArn ${region})"
    local name="$(get_stack_value ${stack_name} LambdaFunctionName ${region})"
    local version="$(aws lambda get-alias --name Live --function-name ${name} --region ${region} | jq -r .FunctionVersion)"

    echo "${arn}:${version}"
}

# create acm certificate
# hard coded to us-east-1 as it will be used by cloudfront
acm_stack_name="${stack_prefix}-certificate"
hosted_zone_id="$(get_stack_value ${stack_prefix}-hosted-zone HostedZoneID)"
aws cloudformation deploy \
    --template-file ./cloudformation/certificate.yaml \
    --stack-name "${acm_stack_name}" \
    --region us-east-1 \
    --parameter-overrides \
        DomainName="${domain_name}" \
        HostedZoneId="${hosted_zone_id}" \
        SubjectAlternativeNames="www.${domain_name}" \
    --no-fail-on-empty-changeset

# uri rewriting lambda edge function
# hard coded to us-east-1 as it will be used by cloudfront
origin_request_stack_name="${stack_prefix}-edge-origin-request"
aws cloudformation deploy \
    --template-file ./cloudformation/edge-pretty-url.yaml \
    --stack-name "${origin_request_stack_name}" \
    --capabilities CAPABILITY_IAM \
    --region us-east-1 \
    --no-fail-on-empty-changeset

# force trailing slash
# hard coded to us-east-1 as it will be used by cloudfront
viewer_request_stack_name="${stack_prefix}-edge-viewer-request"
aws cloudformation deploy \
    --template-file ./cloudformation/edge-trailing-slash.yaml \
    --stack-name "${viewer_request_stack_name}" \
    --capabilities CAPABILITY_IAM \
    --region us-east-1 \
    --no-fail-on-empty-changeset

# s3 static webstite stack
website_stack_name="${stack_prefix}-website"
certificate_arn="$(get_stack_value ${acm_stack_name} CertificateArn us-east-1)"
origin_request_function_arn="$(get_function_version_arn ${origin_request_stack_name} us-east-1)"
viewer_request_function_arn="$(get_function_version_arn ${viewer_request_stack_name} us-east-1)"

echo "${viewer_request_function_arn}"

aws cloudformation deploy \
    --template-file ./cloudformation/static-website.yaml \
    --stack-name "${website_stack_name}" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        HostedZoneStackName="${stack_prefix}-hosted-zone" \
        BucketName="www.${domain_name}" \
        CertificateArn="${certificate_arn}" \
	OriginRequestArn="${origin_request_function_arn}" \
	ViewerRequestArn="${viewer_request_function_arn}" \
        SubDomainName="www." \
    --no-fail-on-empty-changeset

# github actions website deployment role
if [ -n "${repository_name}" ] && [ -n "${github_org}" ]; then
    role_stack_name="${stack_prefix}-website-github-role"
    github_oidc_arn="$(get_stack_value github-oidc-provider OIDCProviderArn)"
    aws cloudformation deploy \
        --template-file ./cloudformation/github-role.yaml \
        --stack-name "${role_stack_name}" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
            WebsiteStackName="${website_stack_name}" \
            OIDCProviderArn="${github_oidc_arn}" \
            RepositoryName="${repository_name}" \
            GitHubOrg="${github_org}" \
        --no-fail-on-empty-changeset
fi

