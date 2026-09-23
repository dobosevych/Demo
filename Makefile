# Deployment entry point. `docker compose up` still runs everything locally;
# this file is only about getting the frontend onto AWS.
#
# Credentials come from .env, never from the shell history and never committed.
# Copy .env.example to .env and fill it in.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------- environment

# Read .env if it is there, and export every name it defines so the aws CLI and
# docker see them.
#
# make reads a shell `export FOO=bar` line natively, but keeps quotes: it would
# read `export FOO='bar'` as the value `'bar'`, quotes and all. So after the
# include, each name .env defines has one pair of surrounding quotes stripped.
# Accepting both the plain and the shell form means a file written either way
# just works, and nothing is written next to .env.
ifneq (,$(wildcard .env))
include .env
_sp := $(subst ,, )
unquote = $(subst __SP__,$(_sp),$(patsubst '%',%,$(patsubst "%",%,$(subst $(_sp),__SP__,$(1)))))
_env_names := $(shell sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' .env)
$(foreach v,$(_env_names),$(eval $(v) := $$(call unquote,$$(value $(v)))))
export
endif

# The aws CLI reads AWS_DEFAULT_REGION; .env is allowed to set either spelling.
# us-east-1: CloudFront takes certificates and web ACLs from there only, and
# everything is kept in one region.
AWS_REGION ?= us-east-1
AWS_DEFAULT_REGION ?= $(AWS_REGION)
export AWS_DEFAULT_REGION

PROJECT_NAME ?= meetings
STACK_NAME ?= $(PROJECT_NAME)-frontend
TEMPLATE := infra/frontend.yaml
BACKEND_TEMPLATE := infra/backend.yaml
BACKEND_STACK ?= $(PROJECT_NAME)-backend

# Custom hostnames, from .env. Empty deploys without them. BACKEND_DOMAIN is
# also the URL the frontend bundle calls; FRONTEND_DOMAIN goes on CloudFront.
BACKEND_DOMAIN ?=
FRONTEND_DOMAIN ?=

# GitHub repository allowed to deploy, as owner/name.
GITHUB_REPO ?=
OIDC_STACK ?= $(PROJECT_NAME)-github-oidc

ECR_REPO ?= $(PROJECT_NAME)-backend
DIST := frontend/dist

# Every stack is deployed with this tag, and CloudFormation copies stack tags onto
# each resource it creates. The templates also set PROJECT_NAME on every taggable
# resource themselves, so it is there however a stack is deployed. The ECR
# repository, made outside CloudFormation, is tagged explicitly. Activate the key under
# Billing > Cost allocation tags to see this app's spend on its own.
TAG_KEY ?= PROJECT_NAME
TAG_VALUE ?= $(PROJECT_NAME)

# $(shell) does not see variables exported from .env in GNU Make 3.81, the one
# macOS ships, so the lookups below hand the AWS settings over explicitly.
# Unset ones are left out, so credentials from the environment (CI) still work.
aws_env = $(foreach v,AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION,$(if $($(v)),$(v)='$($(v))'))

# Pull a stack output by name.
stack_output = $(shell $(aws_env) aws cloudformation describe-stacks \
	--stack-name $(STACK_NAME) \
	--query "Stacks[0].Outputs[?OutputKey=='$(1)'].OutputValue" \
	--output text 2>/dev/null)

backend_output = $(shell $(aws_env) aws cloudformation describe-stacks \
	--stack-name $(BACKEND_STACK) \
	--query "Stacks[0].Outputs[?OutputKey=='$(1)'].OutputValue" \
	--output text 2>/dev/null)

# What the bundle calls, baked in at build time as VITE_API_URL: the backend's
# custom domain if it has one, else its function URL, else empty — the site then
# still deploys and renders, and says it has no backend instead of blanking.
# CloudFront serves only the frontend, so these calls are cross-origin, allowed
# by CORS_ORIGINS.
API_URL = $(filter-out None,$(call backend_output,ApiUrl))
BUNDLE_API_URL = $(if $(BACKEND_DOMAIN),https://$(BACKEND_DOMAIN),$(API_URL))

.PHONY: help aws-check frontend-build infra-deploy frontend-sync frontend-invalidate \
        frontend-deploy frontend-url frontend-status frontend-events frontend-destroy \
        purge-failed-stack explain-failure clean deploy \
        github-oidc github-oidc-verify \
        backend-push backend-deploy backend-url backend-redeploy backend-status \
        backend-logs backend-destroy backend-dns frontend-dns

help: ## Show this help
	@echo "Local development:"
	@echo "  docker compose up            Run postgres, backend and frontend on this machine"
	@echo
	@echo "AWS deployment (credentials are read from .env):"
	@grep -E '^[a-z-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:  STACK_NAME=$(STACK_NAME)  AWS_REGION=$(AWS_REGION)"
	@echo "            BACKEND_DOMAIN=$(BACKEND_DOMAIN)  FRONTEND_DOMAIN=$(FRONTEND_DOMAIN)"

deploy: backend-deploy frontend-deploy ## Deploy everything: backend, then the frontend wired to it

# ------------------------------------------------------------------ preflight

aws-check: ## Verify credentials reach AWS (from .env locally, or the environment in CI)
	@echo "$(PROJECT_NAME)" | grep -Eq '^[a-z0-9-]+$$' || { \
		echo "PROJECT_NAME is '$(PROJECT_NAME)'."; \
		echo "It must be lowercase letters, digits and hyphens only —"; \
		echo "S3 bucket names and ECR repository names reject anything else."; \
		exit 1; \
	}
	@command -v aws >/dev/null || { echo "The aws CLI is not installed."; exit 1; }
	@test -n "$(AWS_DEFAULT_REGION)" || { echo "No region. Set AWS_REGION in .env."; exit 1; }
	@echo "Authenticating against $(AWS_DEFAULT_REGION)…"
	@aws sts get-caller-identity --output table 2>/dev/null || { \
		echo "Could not authenticate with AWS."; \
		test -f .env \
			&& echo "Check AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in .env." \
			|| echo "No .env file. Copy .env.example to .env, or set credentials in the environment (CI)."; \
		exit 1; \
	}

# ---------------------------------------------------------------------- build

frontend-build: ## Build the static bundle into frontend/dist
	@api='$(BUNDLE_API_URL)'; \
	echo "Building the bundle (VITE_API_URL=$${api:-<empty: no backend>})…"; \
	docker build \
		--target build \
		--build-arg VITE_API_URL="$$api" \
		-t $(PROJECT_NAME)-frontend-build \
		./frontend
	@rm -rf $(DIST)
	@cid=$$(docker create $(PROJECT_NAME)-frontend-build) \
		&& docker cp $$cid:/srv/dist $(DIST) >/dev/null \
		&& docker rm $$cid >/dev/null
	@echo "Wrote $(DIST):" && ls -la $(DIST)

# --------------------------------------------------------------------- deploy

infra-deploy: aws-check ## Create or update the S3 + CloudFront stack
	@status=$$(aws cloudformation describe-stacks --stack-name $(STACK_NAME) \
		--query "Stacks[0].StackStatus" --output text 2>/dev/null); \
	if [ "$$status" = "ROLLBACK_COMPLETE" ] || [ "$$status" = "CREATE_FAILED" ]; then \
		echo "Stack $(STACK_NAME) is $$status — a create that failed and rolled back."; \
		echo "CloudFormation cannot update such a stack, so it has to go first."; \
		$(MAKE) --no-print-directory purge-failed-stack; \
	fi
	@echo "Deploying stack $(STACK_NAME)…"
	@test -z "$(FRONTEND_DOMAIN)" || echo "Waiting on the $(FRONTEND_DOMAIN) certificate: run 'make frontend-dns' in another terminal and add the records."
	@aws cloudformation deploy \
		--template-file $(TEMPLATE) \
		--stack-name $(STACK_NAME) \
		--parameter-overrides ProjectName=$(PROJECT_NAME) FrontendDomain='$(FRONTEND_DOMAIN)' \
		--tags $(TAG_KEY)=$(TAG_VALUE) \
		--no-fail-on-empty-changeset \
		|| { $(MAKE) --no-print-directory explain-failure; exit 1; }
	@echo "Bucket:       $(call stack_output,BucketName)"
	@echo "Distribution: $(call stack_output,DistributionId)"

frontend-dns: ## Print the DNS records the site's custom domain needs
	@test -n "$(FRONTEND_DOMAIN)" || { echo "FRONTEND_DOMAIN is empty; no custom domain configured."; exit 1; }
	@cert=$$(aws cloudformation describe-stack-resource --stack-name $(STACK_NAME) \
		--logical-resource-id Certificate \
		--query "StackResourceDetail.PhysicalResourceId" --output text 2>/dev/null); \
	echo; \
	echo "  Add these at the DNS provider for $(FRONTEND_DOMAIN):"; \
	echo; \
	if [ -n "$$cert" ] && [ "$$cert" != "None" ]; then \
		aws acm describe-certificate --certificate-arn "$$cert" \
			--query "Certificate.[Status,DomainValidationOptions[0].ResourceRecord.Name,DomainValidationOptions[0].ResourceRecord.Value]" \
			--output text | while read -r status name value; do \
			echo "  1. Certificate validation ($$status)"; \
			echo "     CNAME  $$name"; \
			echo "        ->  $$value"; \
		done; \
	else \
		echo "  1. Certificate not created yet. Run this again once infra-deploy has started it."; \
	fi; \
	target="$(call stack_output,DistributionDomain)"; \
	echo; \
	if [ -n "$$target" ] && [ "$$target" != "None" ]; then \
		echo "  2. The site itself"; \
		echo "     CNAME  $(FRONTEND_DOMAIN)."; \
		echo "        ->  $$target"; \
	else \
		echo "  2. The site's CNAME target exists once the certificate is issued and the deploy finishes."; \
	fi; \
	echo

frontend-sync: ## Upload frontend/dist to the stack's bucket
	@test -d $(DIST) || { echo "$(DIST) is missing. Run: make frontend-build"; exit 1; }
	@bucket="$(call stack_output,BucketName)"; \
	test -n "$$bucket" -a "$$bucket" != "None" || { \
		echo "Stack $(STACK_NAME) has no BucketName output. Run: make infra-deploy"; exit 1; }; \
	echo "Syncing to s3://$$bucket…"; \
	aws s3 sync $(DIST) "s3://$$bucket" --delete \
		--exclude "index.html" --cache-control "public,max-age=31536000,immutable"; \
	aws s3 cp $(DIST)/index.html "s3://$$bucket/index.html" \
		--cache-control "no-cache,must-revalidate" --content-type "text/html"

frontend-invalidate: ## Invalidate the CloudFront cache
	@dist_id="$(call stack_output,DistributionId)"; \
	test -n "$$dist_id" -a "$$dist_id" != "None" || { \
		echo "Stack $(STACK_NAME) has no DistributionId output. Run: make infra-deploy"; exit 1; }; \
	echo "Invalidating $$dist_id…"; \
	aws cloudfront create-invalidation --distribution-id "$$dist_id" --paths "/*" \
		--query "Invalidation.Id" --output text

frontend-deploy: infra-deploy frontend-build frontend-sync frontend-invalidate frontend-url ## Full frontend deploy: stack, build, upload, invalidate

frontend-url: ## Print the deployed site URL
	@url="$(call stack_output,SiteUrl)"; \
	test -n "$$url" -a "$$url" != "None" || { echo "Stack $(STACK_NAME) is not deployed."; exit 1; }; \
	echo; \
	echo "  $$url"; \
	echo; \
	echo "  A new distribution takes a few minutes to finish deploying."

explain-failure: ## Print why the last stack operation failed, with what to do about it
	@echo
	@echo "CloudFormation reported:"
	@reasons=$$(aws cloudformation describe-stack-events --stack-name $(STACK_NAME) \
		--query "StackEvents[?ResourceStatus=='CREATE_FAILED'||ResourceStatus=='UPDATE_FAILED'||((ResourceStatus=='ROLLBACK_IN_PROGRESS'||ResourceStatus=='UPDATE_ROLLBACK_IN_PROGRESS')&&ResourceStatusReason!=null)].[LogicalResourceId,ResourceStatusReason]" \
		--output text 2>/dev/null | head -n 5); \
	if [ -z "$$reasons" ]; then echo "  (no failure events found)"; else \
		echo "$$reasons" | fold -s -w 100 | sed 's/^/  /'; fi; \
	if echo "$$reasons" | grep -q "must be verified"; then \
		account=$$(aws sts get-caller-identity --query Account --output text 2>/dev/null); \
		echo; \
		echo "  ----------------------------------------------------------------"; \
		echo "  This is a hold on your AWS account, not a fault in this repo."; \
		echo "  CloudFront is not yet enabled for account $$account."; \
		echo; \
		echo "  Open a case: https://console.aws.amazon.com/support/home#/"; \
		echo "    Type:    Account and Billing"; \
		echo "    Subject: CloudFront account verification"; \
		echo "    Body:    paste the error above, including its Request ID"; \
		echo; \
		echo "  Retrying before AWS clears the hold fails exactly the same way."; \
		echo "  ----------------------------------------------------------------"; \
	fi

purge-failed-stack: ## Remove a stack stuck in ROLLBACK_COMPLETE, and any bucket it orphaned
	@status=$$(aws cloudformation describe-stacks --stack-name $(STACK_NAME) \
		--query "Stacks[0].StackStatus" --output text 2>/dev/null); \
	case "$$status" in \
		ROLLBACK_COMPLETE|CREATE_FAILED) ;; \
		"") echo "Stack $(STACK_NAME) does not exist. Nothing to purge."; exit 0 ;; \
		*) echo "Stack $(STACK_NAME) is $$status, not a failed create. Refusing to delete it."; \
		   echo "Use 'make frontend-destroy CONFIRM=yes' if you really mean to remove it."; \
		   exit 1 ;; \
	esac; \
	account=$$(aws sts get-caller-identity --query Account --output text); \
	bucket="$(PROJECT_NAME)-frontend-$$account-$(AWS_DEFAULT_REGION)"; \
	if aws s3api head-bucket --bucket "$$bucket" >/dev/null 2>&1; then \
		echo "  deleting orphaned s3://$$bucket (build output only)"; \
		aws s3 rm "s3://$$bucket" --recursive >/dev/null; \
		aws s3api delete-bucket --bucket "$$bucket"; \
	fi; \
	echo "  deleting stack $(STACK_NAME)"; \
	aws cloudformation delete-stack --stack-name $(STACK_NAME); \
	aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME); \
	echo "  done — the next deploy starts clean."

frontend-status: ## Show the stack's current status
	@aws cloudformation describe-stacks --stack-name $(STACK_NAME) \
		--query "Stacks[0].[StackName,StackStatus,LastUpdatedTime]" --output table \
		|| echo "Stack $(STACK_NAME) does not exist in $(AWS_DEFAULT_REGION)."

frontend-events: ## Show recent stack events, newest first (use this when a deploy fails)
	@aws cloudformation describe-stack-events --stack-name $(STACK_NAME) \
		--max-items 40 \
		--query "StackEvents[].[Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason]" \
		--output table

github-oidc: aws-check ## Create the IAM role GitHub Actions assumes (no stored credentials)
	@test -n "$(GITHUB_REPO)" || { \
		echo "GITHUB_REPO is not set. Add it to .env, e.g. GITHUB_REPO=owner/repo"; \
		exit 1; \
	}
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	arn="arn:aws:iam::$$account:oidc-provider/token.actions.githubusercontent.com"; \
	exists=no; \
	aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$$arn" >/dev/null 2>&1 && exists=yes; \
	mine=no; \
	aws cloudformation describe-stack-resource --stack-name $(OIDC_STACK) \
		--logical-resource-id GitHubOidcProvider >/dev/null 2>&1 && mine=yes; \
	if [ "$$mine" = "yes" ]; then \
		create=yes; \
		echo "OIDC provider exists and this stack owns it — keeping it."; \
	elif [ "$$exists" = "yes" ]; then \
		create=no; \
		echo "OIDC provider exists but belongs to something else — leaving it in place."; \
		if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$$arn" \
			--query "ClientIDList" --output text | tr '\t' '\n' | grep -qx "sts.amazonaws.com"; then \
			echo "  audience sts.amazonaws.com: present"; \
		else \
			echo "  audience sts.amazonaws.com: MISSING — adding it"; \
			aws iam add-client-id-to-open-id-connect-provider \
				--open-id-connect-provider-arn "$$arn" \
				--client-id sts.amazonaws.com; \
			echo "  added."; \
		fi; \
	else \
		create=yes; \
		echo "No OIDC provider yet — this stack will create one."; \
	fi; \
	echo "Deploying $(OIDC_STACK) for $(GITHUB_REPO) (create provider: $$create)…"; \
	aws cloudformation deploy \
		--template-file infra/github-oidc.yaml \
		--stack-name $(OIDC_STACK) \
		--capabilities CAPABILITY_NAMED_IAM \
		--tags $(TAG_KEY)=$(TAG_VALUE) \
		--no-fail-on-empty-changeset \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			GitHubRepo=$(GITHUB_REPO) \
			CreateOidcProvider=$$create \
		|| { $(MAKE) --no-print-directory STACK_NAME=$(OIDC_STACK) explain-failure; exit 1; }
	@$(MAKE) --no-print-directory github-oidc-verify

github-oidc-verify: ## Check the provider audience and role trust are actually usable
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	arn="arn:aws:iam::$$account:oidc-provider/token.actions.githubusercontent.com"; \
	echo; \
	echo "  Verifying what GitHub will actually be checked against:"; \
	echo; \
	aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$$arn" \
		--query "ClientIDList" --output text | tr '\t' '\n' | grep -qx "sts.amazonaws.com" \
		&& echo "    audience sts.amazonaws.com .. OK" \
		|| { echo "    audience sts.amazonaws.com .. MISSING"; exit 1; }; \
	role="$(PROJECT_NAME)-github-deploy"; \
	aws iam get-role --role-name "$$role" \
		--query "Role.AssumeRolePolicyDocument.Statement[0].Principal.Federated" --output text \
		| grep -q "token.actions.githubusercontent.com" \
		&& echo "    role trusts the GitHub provider .. OK" \
		|| { echo "    role trusts the GitHub provider .. NO"; exit 1; }; \
	echo "    subject patterns the role accepts:"; \
	aws iam get-role --role-name "$$role" \
		--query "Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike.*" --output text \
		| tr '\t' '\n' | sed 's/^/      /'; \
	echo; \
	echo "  A workflow subject must match one of those. GitHub sends the"; \
	echo "  immutable form, repo:owner@<id>/name@<id>:..., on newer repositories."; \
	echo; \
	arn_out=$$(aws iam get-role --role-name "$$role" --query "Role.Arn" --output text); \
	echo "  AWS_ROLE_ARN repository variable:"; \
	echo "    $$arn_out"

# -------------------------------------------------------------------- backend

# The image as pushed, pinned by digest so a new push is a change the stack sees.
image_by_digest = $$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com/$(ECR_REPO)@$$(aws ecr describe-images --repository-name $(ECR_REPO) --image-ids imageTag=latest --query "imageDetails[0].imageDigest" --output text)

backend-push: aws-check ## Build the backend image and push it to ECR
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	registry="$$account.dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com"; \
	image="$$registry/$(ECR_REPO):latest"; \
	aws ecr describe-repositories --repository-names $(ECR_REPO) >/dev/null 2>&1 \
		|| { echo "Creating ECR repository $(ECR_REPO)…"; \
		     aws ecr create-repository --repository-name $(ECR_REPO) \
		       --image-scanning-configuration scanOnPush=true >/dev/null; }; \
	aws ecr tag-resource \
		--resource-arn "arn:aws:ecr:$(AWS_DEFAULT_REGION):$$account:repository/$(ECR_REPO)" \
		--tags Key=$(TAG_KEY),Value=$(TAG_VALUE); \
	echo "Logging in to $$registry…"; \
	aws ecr get-login-password | docker login --username AWS --password-stdin "$$registry"; \
	echo "Building $$image…"; \
	docker build --platform linux/amd64 --provenance=false -t "$$image" ./backend; \
	echo "Pushing…"; \
	docker push "$$image"; \
	echo "Pushed $$image"

# --provenance=false above is required: Lambda rejects the multi-manifest image
# index that buildx produces when it attaches provenance attestations.

backend-deploy: backend-push ## Deploy the database and the API, then print the URL
	@test -n "$(DB_PASSWORD)" || { \
		echo "DB_PASSWORD is not set in .env. Add one (8+ chars, no / @ \" or space)."; \
		exit 1; \
	}
	@status=$$(aws cloudformation describe-stacks --stack-name $(BACKEND_STACK) \
		--query "Stacks[0].StackStatus" --output text 2>/dev/null); \
	if [ "$$status" = "ROLLBACK_COMPLETE" ] || [ "$$status" = "CREATE_FAILED" ]; then \
		echo "Stack $(BACKEND_STACK) is $$status — clearing it first."; \
		aws cloudformation delete-stack --stack-name $(BACKEND_STACK); \
		aws cloudformation wait stack-delete-complete --stack-name $(BACKEND_STACK); \
	fi
	@image="$(image_by_digest)"; \
	echo "Deploying stack $(BACKEND_STACK) with $$image"; \
	echo "Creating the Aurora cluster takes ~10 minutes the first time…"; \
	aws cloudformation deploy \
		--template-file $(BACKEND_TEMPLATE) \
		--stack-name $(BACKEND_STACK) \
		--capabilities CAPABILITY_IAM \
		--tags $(TAG_KEY)=$(TAG_VALUE) \
		--no-fail-on-empty-changeset \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			ImageUri="$$image" \
			DbPassword='$(DB_PASSWORD)' \
			CorsOrigins='$(CORS_ORIGINS)' \
			BackendDomainName='$(BACKEND_DOMAIN)' \
		|| { $(MAKE) --no-print-directory STACK_NAME=$(BACKEND_STACK) explain-failure; exit 1; }
	@$(MAKE) --no-print-directory backend-url

backend-url: ## Print the deployed API URL
	@url="$(call backend_output,ApiUrl)"; \
	test -n "$$url" -a "$$url" != "None" || { echo "Stack $(BACKEND_STACK) is not deployed."; exit 1; }; \
	echo; \
	echo "  Function URL: $$url"; \
	echo; \
	echo "  The frontend calls it directly; CloudFront serves only the static site."; \
	echo "  After the first backend deploy, rebuild the bundle with: make frontend-deploy"; \
	echo; \
	echo "  The first request after the database has paused takes ~20 seconds."; \
	domain="$(call backend_output,ApiDomainUrl)"; \
	if [ -n "$$domain" ] && [ "$$domain" != "None" ]; then \
		echo; \
		echo "  Custom domain: $$domain  (see: make backend-dns)"; \
	fi

backend-dns: ## Print the DNS records the API's custom domain needs
	@test -n "$(BACKEND_DOMAIN)" || { echo "BACKEND_DOMAIN is empty; no custom domain configured."; exit 1; }
	@cert=$$(aws cloudformation describe-stack-resource --stack-name $(BACKEND_STACK) \
		--logical-resource-id ApiCertificate \
		--query "StackResourceDetail.PhysicalResourceId" --output text 2>/dev/null); \
	echo; \
	echo "  Add these at the DNS provider for $(BACKEND_DOMAIN):"; \
	echo; \
	if [ -n "$$cert" ] && [ "$$cert" != "None" ]; then \
		aws acm describe-certificate --certificate-arn "$$cert" \
			--query "Certificate.[Status,DomainValidationOptions[0].ResourceRecord.Name,DomainValidationOptions[0].ResourceRecord.Value]" \
			--output text | while read -r status name value; do \
			echo "  1. Certificate validation ($$status)"; \
			echo "     CNAME  $$name"; \
			echo "        ->  $$value"; \
		done; \
	else \
		echo "  1. Certificate not created yet. Run this again once backend-deploy has started it."; \
	fi; \
	target="$(call backend_output,ApiDomainTarget)"; \
	echo; \
	if [ -n "$$target" ] && [ "$$target" != "None" ]; then \
		echo "  2. The API itself"; \
		echo "     CNAME  $(BACKEND_DOMAIN)."; \
		echo "        ->  $$target"; \
	else \
		echo "  2. The API's CNAME target exists once the certificate is issued and the deploy finishes."; \
	fi; \
	echo

backend-redeploy: backend-push ## Push a new image and point the function at it
	@fn="$(call backend_output,FunctionName)"; \
	test -n "$$fn" -a "$$fn" != "None" || { echo "Stack $(BACKEND_STACK) is not deployed."; exit 1; }; \
	image="$(image_by_digest)"; \
	echo "Updating $$fn to $$image…"; \
	aws lambda update-function-code --function-name "$$fn" --image-uri "$$image" \
		--query "LastUpdateStatus" --output text; \
	aws lambda wait function-updated-v2 --function-name "$$fn" && echo "Done."; \
	echo "The stack still names the previous digest; the next 'make backend-deploy' reconciles it."

backend-status: ## Show the function's state and whether the database is running or paused
	@fn="$(call backend_output,FunctionName)"; \
	db="$(call backend_output,DbClusterId)"; \
	test -n "$$fn" -a "$$fn" != "None" || { echo "Stack $(BACKEND_STACK) is not deployed."; exit 1; }; \
	aws lambda get-function-configuration --function-name "$$fn" \
		--query "[FunctionName,State,LastUpdateStatus,LastModified]" --output table; \
	aws rds describe-db-clusters --db-cluster-identifier "$$db" \
		--query "DBClusters[0].[DBClusterIdentifier,Status,ServerlessV2ScalingConfiguration.MinCapacity,ServerlessV2ScalingConfiguration.MaxCapacity]" \
		--output table; \
	acu=$$(aws cloudwatch get-metric-statistics --namespace AWS/RDS \
		--metric-name ServerlessDatabaseCapacity --dimensions Name=DBClusterIdentifier,Value="$$db" \
		--start-time "$$(date -u -v-10M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
		--end-time "$$(date -u +%Y-%m-%dT%H:%M:%S)" --period 60 --statistics Maximum \
		--query "sort_by(Datapoints,&Timestamp)[-1].Maximum" --output text); \
	echo "Database capacity in the last minutes: $$acu ACU (0 means paused)"

backend-logs: ## Tail the API's application logs
	@aws logs tail "/aws/lambda/$(PROJECT_NAME)-backend" --follow --since 10m \
		|| echo "No log group yet. The function has to run once first."

backend-destroy: aws-check ## Delete the API, the database and the VPC (requires CONFIRM=yes)
	@test "$(CONFIRM)" = "yes" || { \
		echo "This permanently deletes the API, the database AND ALL ITS DATA."; \
		echo "Re-run as: make backend-destroy CONFIRM=yes"; \
		exit 1; \
	}
	@aws cloudformation delete-stack --stack-name $(BACKEND_STACK)
	@echo "Delete requested. Watch it with:"
	@echo "  aws cloudformation wait stack-delete-complete --stack-name $(BACKEND_STACK)"

# -------------------------------------------------------------------- teardown

frontend-destroy: aws-check ## Delete the stack and its bucket (requires CONFIRM=yes)
	@test "$(CONFIRM)" = "yes" || { \
		echo "This permanently deletes the bucket, its contents and the distribution."; \
		echo "Re-run as: make frontend-destroy CONFIRM=yes"; \
		exit 1; \
	}
	@bucket="$(call stack_output,BucketName)"; \
	if [ -n "$$bucket" ] && [ "$$bucket" != "None" ]; then \
		echo "Emptying s3://$$bucket…"; \
		aws s3 rm "s3://$$bucket" --recursive; \
		aws s3api delete-bucket --bucket "$$bucket"; \
	fi
	@aws cloudformation delete-stack --stack-name $(STACK_NAME)
	@echo "Delete requested. Watch it with:"
	@echo "  aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME)"

clean: ## Remove the local build output
	@rm -rf $(DIST)
	@echo "Removed $(DIST)"
