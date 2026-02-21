AWS_ACCOUNT_ID := 677459762413
AWS_DEFAULT_REGION := us-west-2
AWS_ECR_DOMAIN := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com
GIT_SHA := $(shell git rev-parse HEAD)
BUILD_IMAGE := $(AWS_ECR_DOMAIN)/fem-fd-service
BUILD_TAG := $(if $(BUILD_TAG),$(BUILD_TAG),latest)

build-image:
	docker buildx build \
		--platform "linux/amd64" \
		--tag "$(BUILD_IMAGE):$(GIT_SHA)-build" \
		--target "build" \
		.
	docker buildx build \
		--cache-from "$(BUILD_IMAGE):$(GIT_SHA)-build" \
		--platform "linux/amd64" \
		--tag "$(BUILD_IMAGE):$(GIT_SHA)" \
		.

build-image-login:
	aws ecr get-login-password --region $(AWS_DEFAULT_REGION) | docker login \
		--username AWS \
		--password-stdin \
		$(AWS_ECR_DOMAIN)

build-image-push: build-image-login
	docker image push $(BUILD_IMAGE):$(GIT_SHA)

build-image-pull: build-image-login
	docker image pull $(BUILD_IMAGE):$(GIT_SHA)

build-image-promote:
	docker image tag $(BUILD_IMAGE):$(GIT_SHA) $(BUILD_IMAGE):$(BUILD_TAG)
	docker image push $(BUILD_IMAGE):$(BUILD_TAG)

deploy:
	AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) \
	AWS_DEFAULT_REGION=$(AWS_DEFAULT_REGION) \
	AWS_ECR_DOMAIN=$(AWS_ECR_DOMAIN) \
	./deploy.sh
