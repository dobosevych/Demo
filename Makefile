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
# .env is normalised first, into .env.make, because make does not strip quotes
# and does not understand a shell `export` prefix: it would read
# `export FOO='bar'` as the value `'bar'`, quotes and all. Accepting both the
# plain and the shell form means a file written either way just works.
ifneq (,$(wildcard .env))
_normalise := $(shell sed -E \
	-e 's/^[[:space:]]*export[[:space:]]+//' \
	-e "s/^([A-Za-z_][A-Za-z0-9_]*)='(.*)'[[:space:]]*$$/\1=\2/" \
	-e 's/^([A-Za-z_][A-Za-z0-9_]*)="(.*)"[[:space:]]*$$/\1=\2/' \
	.env > .env.make)
include .env.make
export
endif

# The aws CLI reads AWS_DEFAULT_REGION; .env is allowed to set either spelling.
AWS_REGION ?= us-east-1
AWS_DEFAULT_REGION ?= $(AWS_REGION)
export AWS_DEFAULT_REGION

PROJECT_NAME ?= meetings
STACK_NAME ?= $(PROJECT_NAME)-frontend
TEMPLATE := infra/frontend.yaml
BACKEND_TEMPLATE := infra/backend.yaml
BACKEND_STACK ?= $(PROJECT_NAME)-backend

# Domain for the API. Empty means the load balancer answers on HTTP only.
API_DOMAIN ?=
# GitHub repository allowed to deploy, as owner/name.
GITHUB_REPO ?=
OIDC_STACK ?= $(PROJECT_NAME)-github-oidc

# The registrable zone, derived from API_DOMAIN: demo.example.com -> example.com
DOMAIN_ZONE = $(shell echo '$(API_DOMAIN)' | cut -d. -f2-)
ECR_REPO ?= $(PROJECT_NAME)-backend
DIST := frontend/dist

# Baked into the bundle at build time. Empty is deliberate and supported: the
# site deploys and renders, and says it has no backend instead of blanking.
VITE_API_URL ?=

# Pull a stack output by name.
stack_output = $(shell aws cloudformation describe-stacks \
	--stack-name $(STACK_NAME) \
	--query "Stacks[0].Outputs[?OutputKey=='$(1)'].OutputValue" \
	--output text 2>/dev/null)

backend_output = $(shell aws cloudformation describe-stacks \
	--stack-name $(BACKEND_STACK) \
	--query "Stacks[0].Outputs[?OutputKey=='$(1)'].OutputValue" \
	--output text 2>/dev/null)

.PHONY: help aws-check frontend-build infra-deploy frontend-sync frontend-invalidate \
        frontend-deploy frontend-url frontend-status frontend-events frontend-destroy \
        purge-failed-stack explain-failure env-export clean cert cert-wait \
        github-oidc github-oidc-verify \
        backend-push backend-deploy backend-url backend-redeploy backend-status \
        backend-logs backend-destroy

help: ## Show this help
	@echo "Local development:"
	@echo "  docker compose up            Run postgres, backend and frontend on this machine"
	@echo
	@echo "AWS deployment (credentials are read from .env):"
	@grep -E '^[a-z-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:  STACK_NAME=$(STACK_NAME)  AWS_REGION=$(AWS_REGION)"
	@echo "            VITE_API_URL=$(if $(VITE_API_URL),$(VITE_API_URL),<empty: deploys without a backend>)"

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
	@echo "Building the bundle (VITE_API_URL=$(if $(VITE_API_URL),$(VITE_API_URL),<empty>))…"
	@docker build \
		--target build \
		--build-arg VITE_API_URL=$(VITE_API_URL) \
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
	@aws cloudformation deploy \
		--template-file $(TEMPLATE) \
		--stack-name $(STACK_NAME) \
		--parameter-overrides ProjectName=$(PROJECT_NAME) \
		--no-fail-on-empty-changeset \
		|| { $(MAKE) --no-print-directory explain-failure; exit 1; }
	@echo "Bucket:       $(call stack_output,BucketName)"
	@echo "Distribution: $(call stack_output,DistributionId)"

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
		--query "StackEvents[?ResourceStatus=='CREATE_FAILED'||ResourceStatus=='UPDATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
		--output text 2>/dev/null); \
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

env-export: ## Write .env.sh, a safely quoted version of .env you can source
	@sed -E -e "/^[[:space:]]*(\#|$$)/d" -e "s/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$$/export \1='\2'/" .env > .env.sh
	@echo "Wrote .env.sh. Load it into your shell with:"
	@echo
	@echo "  source .env.sh"
	@echo
	@echo "Quoting it is why this file exists: 'source .env' breaks in zsh when a"
	@echo "value contains ( ) < > or spaces, which .env leaves unquoted for make."

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

# --------------------------------------------------------------- certificate

cert: aws-check ## Request the HTTPS certificate for API_DOMAIN and show the DNS record to add
	@test -n "$(API_DOMAIN)" || { \
		echo "API_DOMAIN is not set in .env. Add e.g. API_DOMAIN=demo.example.com"; \
		exit 1; \
	}
	@arn=$$(aws acm list-certificates \
		--query "CertificateSummaryList[?DomainName=='$(API_DOMAIN)'].CertificateArn | [0]" \
		--output text); \
	if [ -z "$$arn" ] || [ "$$arn" = "None" ]; then \
		echo "Requesting a certificate for $(API_DOMAIN)…"; \
		arn=$$(aws acm request-certificate --domain-name $(API_DOMAIN) \
			--validation-method DNS --query CertificateArn --output text); \
		echo "Waiting for the validation record to be issued…"; \
		for i in 1 2 3 4 5 6; do \
			name=$$(aws acm describe-certificate --certificate-arn "$$arn" \
				--query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text 2>/dev/null); \
			[ -n "$$name" ] && [ "$$name" != "None" ] && break; \
			sleep 5; \
		done; \
	fi; \
	status=$$(aws acm describe-certificate --certificate-arn "$$arn" --query "Certificate.Status" --output text); \
	echo; \
	echo "  Certificate: $$arn"; \
	echo "  Status:      $$status"; \
	if [ "$$status" = "ISSUED" ]; then \
		echo; \
		echo "  Validated. Deploy with: make backend-deploy"; \
	else \
		name=$$(aws acm describe-certificate --certificate-arn "$$arn" \
			--query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text); \
		value=$$(aws acm describe-certificate --certificate-arn "$$arn" \
			--query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" --output text); \
		host=$$(echo "$$name" | sed -e "s/\.$$//" -e "s/\.$(DOMAIN_ZONE)$$//"); \
		echo; \
		echo "  ---- Add this CNAME at your DNS provider, then run: make cert-wait ----"; \
		echo; \
		echo "    Type:      CNAME"; \
		echo "    Full name: $$name"; \
		echo "    Host/name: $$host      <- most panels want only this part"; \
		echo "    Value:     $$value"; \
		echo; \
		echo "  The trailing dot is not typed. AWS checks this record to prove you"; \
		echo "  own the domain; it must stay in place for the certificate's life."; \
	fi

cert-wait: ## Block until the certificate is validated and issued
	@arn=$$(aws acm list-certificates \
		--query "CertificateSummaryList[?DomainName=='$(API_DOMAIN)'].CertificateArn | [0]" \
		--output text); \
	test -n "$$arn" -a "$$arn" != "None" || { echo "No certificate for $(API_DOMAIN). Run: make cert"; exit 1; }; \
	echo "Waiting for $(API_DOMAIN) to validate (DNS can take a few minutes)…"; \
	aws acm wait certificate-validated --certificate-arn "$$arn" \
		&& echo "Issued. Now run: make backend-deploy"

# -------------------------------------------------------------------- backend

backend-push: aws-check ## Build the backend image and push it to ECR
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	registry="$$account.dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com"; \
	image="$$registry/$(ECR_REPO):latest"; \
	aws ecr describe-repositories --repository-names $(ECR_REPO) >/dev/null 2>&1 \
		|| { echo "Creating ECR repository $(ECR_REPO)…"; \
		     aws ecr create-repository --repository-name $(ECR_REPO) \
		       --image-scanning-configuration scanOnPush=true >/dev/null; }; \
	echo "Logging in to $$registry…"; \
	aws ecr get-login-password | docker login --username AWS --password-stdin "$$registry"; \
	echo "Building $$image…"; \
	docker build --platform linux/amd64 -t "$$image" ./backend; \
	echo "Pushing…"; \
	docker push "$$image"; \
	echo "Pushed $$image"

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
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	image="$$account.dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com/$(ECR_REPO):latest"; \
	cert=""; \
	if [ -n "$(API_DOMAIN)" ]; then \
		cert=$$(aws acm list-certificates --certificate-statuses ISSUED \
			--query "CertificateSummaryList[?DomainName=='$(API_DOMAIN)'].CertificateArn | [0]" \
			--output text); \
		if [ -z "$$cert" ] || [ "$$cert" = "None" ]; then \
			echo "API_DOMAIN is $(API_DOMAIN) but no ISSUED certificate exists for it."; \
			echo "Run 'make cert', add the DNS record, then 'make cert-wait'."; \
			exit 1; \
		fi; \
		echo "Using certificate $$cert"; \
	fi; \
	echo "Deploying stack $(BACKEND_STACK) — RDS and the load balancer take ~10 minutes…"; \
	aws cloudformation deploy \
		--template-file $(BACKEND_TEMPLATE) \
		--stack-name $(BACKEND_STACK) \
		--capabilities CAPABILITY_IAM \
		--no-fail-on-empty-changeset \
		--parameter-overrides \
			ProjectName=$(PROJECT_NAME) \
			ImageUri="$$image" \
			DbPassword='$(DB_PASSWORD)' \
			CorsOrigins='$(CORS_ORIGINS)' \
			DomainName='$(API_DOMAIN)' \
			CertificateArn="$$cert" \
		|| { $(MAKE) --no-print-directory STACK_NAME=$(BACKEND_STACK) explain-failure; exit 1; }
	@$(MAKE) --no-print-directory backend-url

backend-url: ## Print the deployed API URL
	@url="$(call backend_output,ApiUrl)"; \
	test -n "$$url" -a "$$url" != "None" || { echo "Stack $(BACKEND_STACK) is not deployed."; exit 1; }; \
	echo; \
	echo "  $$url"; \
	echo; \
	if [ -n "$(API_DOMAIN)" ]; then \
		lb="$(call backend_output,LoadBalancerDomain)"; \
		echo "  For that URL to resolve, this CNAME must exist at your DNS provider:"; \
		echo "    Host:  $$(echo $(API_DOMAIN) | cut -d. -f1)"; \
		echo "    Value: $$lb"; \
		echo; \
	fi; \
	echo "  Point the frontend at it by setting this in .env, then redeploying:"; \
	echo "    VITE_API_URL=$$url"; \
	echo "    make frontend-deploy"

backend-redeploy: backend-push ## Push a new image and roll the running service onto it
	@cluster="$(call backend_output,ClusterName)"; \
	service="$(call backend_output,ServiceName)"; \
	test -n "$$cluster" -a "$$cluster" != "None" || { echo "Stack $(BACKEND_STACK) is not deployed."; exit 1; }; \
	echo "Rolling $$service onto the new image…"; \
	aws ecs update-service --cluster "$$cluster" --service "$$service" \
		--force-new-deployment --query "service.deployments[0].status" --output text; \
	echo "Watch it finish with: make backend-status"

backend-status: ## Show the running task count and deployment state
	@cluster="$(call backend_output,ClusterName)"; \
	service="$(call backend_output,ServiceName)"; \
	test -n "$$cluster" -a "$$cluster" != "None" || { echo "Stack $(BACKEND_STACK) is not deployed."; exit 1; }; \
	aws ecs describe-services --cluster "$$cluster" --services "$$service" \
		--query "services[0].[status,desiredCount,runningCount,pendingCount]" --output table

backend-logs: ## Tail the API's application logs
	@aws logs tail "/aws/apprunner/$(PROJECT_NAME)-backend" --follow --since 10m \
		|| echo "No log group yet. The service has to start once first."

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

clean: ## Remove the local build output and generated env files
	@rm -rf $(DIST) .env.make .env.sh
	@echo "Removed $(DIST), .env.make and .env.sh"
