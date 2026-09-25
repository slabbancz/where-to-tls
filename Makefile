-include .env

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Set true to apply the full desired state and remove resources outside SCENARIO.
CLEAN       ?= false

TOFU        ?= tofu
TOFU_DISPLAY_ARGS ?= -compact-warnings
HELM        ?= helm
KUBECONFIG  ?= $(CURDIR)/results/kubeconfig
IAC_DIR     := iac/azure
APP_CHART   := charts/apps
ANALYZE_DIR := analyze
ANALYZE_CHART_DIR := $(ANALYZE_DIR)/chart
ANALYZE_PODMAN_DIR := $(ANALYZE_DIR)/podman
ANALYZE_RELEASE ?= wtt-analyze
NAMESPACE   ?= wtt
MONITORING_NAMESPACE ?= wtt-monitoring
MONITORING_RELEASE ?= wtt-monitoring
PYROSCOPE_RELEASE ?= wtt-pyroscope
WORKLOAD_RELEASE ?= wtt-workload
VMSS        ?=
JUMPBOX_IMAGE ?= alpine:edge
SCENARIOS   ?=
IMPORT_SKIP_WARMUP ?= true
ANALYZE_LIST_LIMIT ?= 200

# Immutable image tags: contract section 4 forbids `latest`.
GIT_SHA         := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit)
WORKTREE_SUFFIX := $(shell test -n "$$(git status --porcelain 2>/dev/null)" && date -u +'-wip-%Y%m%dT%H%M%S')

#TAG             ?= $(GIT_SHA)$(WORKTREE_SUFFIX)
TAG             ?=dev

# Resolved lazily; only targets that reference ACR invoke OpenTofu.
ACR = $(shell cd $(IAC_DIR) && $(TOFU) output -raw acr_login_server 2>/dev/null)

AVAILABLE_SCENARIOS := \
  c0-cluster-only c0-vm-only \
  s1-iis-netfx \
  s2-vm-net s2-vm-java s2-vm-go s2-vm-rust \
  s4-k8s-pod-net s4-k8s-pod-java s4-k8s-pod-go s4-k8s-pod-rust \
  s5-traefik-passthrough-net s5-traefik-passthrough-java s5-traefik-passthrough-go s5-traefik-passthrough-rust \
  s6-traefik-terminate-net s6-traefik-terminate-java s6-traefik-terminate-go s6-traefik-terminate-rust \
  c2-vm-net-plain c2-vm-java-plain c2-vm-go-plain c2-vm-rust-plain \
  c4-k8s-pod-net-plain c4-k8s-pod-java-plain c4-k8s-pod-go-plain c4-k8s-pod-rust-plain

K8S_SCENARIOS := \
  s4-k8s-pod-net s4-k8s-pod-java s4-k8s-pod-go s4-k8s-pod-rust \
  s5-traefik-passthrough-net s5-traefik-passthrough-java s5-traefik-passthrough-go s5-traefik-passthrough-rust \
  s6-traefik-terminate-net s6-traefik-terminate-java s6-traefik-terminate-go s6-traefik-terminate-rust \
  c4-k8s-pod-net-plain c4-k8s-pod-java-plain c4-k8s-pod-go-plain c4-k8s-pod-rust-plain

K8S_VALUES = charts/apps/scenarios/$(SCENARIO).yaml

# TLS_VERSION: 1.2 / 1.3; TLS_GROUP: P-256 / X25519.
TLS_VERSION ?= 1.2
TLS_GROUP ?= P-256
# JAVA_TLS_PROVIDER: boringssl / jdk.
JAVA_TLS_PROVIDER ?= boringssl
DOTNET_AOT ?= false
# IMAGE_BASE: alpine / deb (.NET and Java: resolute; Go and Rust: trixie).
IMAGE_BASE ?= deb
PAYLOAD_PREALLOCATE ?= true
TLS_HANDSHAKE_TIMEOUT_SECONDS ?= 5
HTTP_REQUEST_TIMEOUT_SECONDS ?= 10
BENCH_CONFIG ?=
BENCH_RUN_CONFIG ?= results/bench-run.json

.PHONY: help
help:
	@echo "where-to-tls -- TLS termination benchmark"
	@echo "  SCENARIO values:"
	@printf '    %s\n' $(AVAILABLE_SCENARIOS)
	@echo "  Infrastructure"
	@printf '    %-66s %s\n' "init" "initialize OpenTofu"
	@printf '    %-66s %s\n' "validate" "validate OpenTofu and Helm assets"
	@printf '    %-66s %s\n' "plan SCENARIO=<id>" "plan one scenario"
	@printf '    %-66s %s\n' "apply SCENARIO=<id>" "provision one scenario"
	@printf '    %-66s %s\n' "destroy" "destroy all Azure resources"
	@printf '    %-66s %s\n' "outputs" "show OpenTofu outputs"
	@echo "  Images"
	@printf '    %-66s %s\n' "build TAG=<tag> [IMAGE_BASE=alpine|deb]" "build server images"
	@printf '    %-66s %s\n' "push TAG=<tag> [IMAGE_BASE=alpine|deb]" "build and push server images"
	@printf '    %-66s %s\n' "images TAG=<tag> [IMAGE_BASE=alpine|deb]" "build and push server images"
	@printf '    %-66s %s\n' "podman-login" "authenticate Podman to the active ACR"
	@echo "  Benchmark"
	@printf '    %-66s %s\n' "deploy SCENARIO=<id> TAG=<tag>" "configure k8s when needed and deploy a provisioned scenario image"
	@printf '    %-66s %s\n' "bench-plan SCENARIO=<id> BENCH_CONFIG=<yaml>" "render a scenario-resolved benchmark JSON"
	@printf '    %-66s %s\n' "bench SCENARIO=<id> BENCH_CONFIG=<yaml>" "run asynchronously on the client agent and poll"
	@printf '    %-66s %s\n' "bench-run SCENARIO=<id> BENCH_CONFIG=<yaml>" "start the benchmark agent job and return"
	@printf '    %-66s %s\n' "bench-status BENCH_RUN_CONFIG=<json>" "poll the agent until completion"
	@printf '    %-66s %s\n' "bench-get BENCH_RUN_CONFIG=<json>" "download completed benchmark results"
	@printf '    %-66s %s\n' "scenario SCENARIO=<id> BENCH_CONFIG=<yaml>" "provision, publish, deploy, and benchmark"
	@printf '    %-66s %s\n' "scenarios SCENARIOS=\"<id> ...\" BENCH_CONFIG=<yaml> TAG=<tag>" "run one workload serially"
	@echo "  Apps/charts"
	@printf '    %-66s %s\n' "charts" "refresh vendored chart archives"
	@echo "  Debug"
	@printf '    %-66s %s\n' "jumpbox" "provision the private ACI jumpbox"
	@printf '    %-66s %s\n' "jump" "open /bin/sh in the jumpbox"
	@printf '    %-66s %s\n' "kubectl CMD=\"get nodes -o wide\"" "run kubectl on the control plane"
	@printf '    %-66s %s\n' "reimage VMSS=<name>" "reimage all instances in one VMSS pool"
	@printf '    %-66s %s\n' "reimagefull VMSS=<name>" "reimage all managed disks in one VMSS pool"
	@printf '    %-66s %s\n' "reimageall" "reimage all benchmark VMSS pools"
	@printf '    %-66s %s\n' "analyze-up" "start local Grafana and InfluxDB"
	@printf '    %-66s %s\n' "analyze-up[-oci] IMPORT_SKIP_WARMUP=true" "start local importer without warm-up points"
	@printf '    %-66s %s\n' "analyze-up-oci IMPORT_ARTIFACT_IMAGES=\"<ref> ...\"" "start local stack with OCI result imports"
	@printf '    %-66s %s\n' "analyze-pod IMPORT_ARTIFACT_IMAGES=\"<ref> ...\" IMPORT_SKIP_WARMUP=true" "install chart and optionally skip warm-up"
	@printf '    %-66s %s\n' "analyze-list [ANALYZE_LIST_LIMIT=100]" "list available benchmark-result OCI references"
	@printf '    %-66s %s\n' "analyze-get ARTIFACT_IMAGES=\"<ref> ...\"" "download and extract OCI result artifacts"
	@printf '    %-66s %s\n' "analyze-influx-forward" "forward Helm InfluxDB to localhost:8086"
	@printf '    %-66s %s\n' "analyze-down" "stop local Grafana and InfluxDB"
	@printf '    %-66s %s\n' "analyze-pod" "install the control-plane analysis chart"
	@printf '    %-66s %s\n' "analyze-forward" "port-forward Grafana to localhost:3000"
	@printf '    %-66s %s\n' "cluster-create" "create cluster infrastructure only"
	@printf '    %-66s %s\n' "cluster-configure" "install vendored cluster components"
	@printf '    %-66s %s\n' "cluster-monitoring" "install metrics monitoring and wtt-scoped continuous profiling"
	@printf '    %-66s %s\n' "cluster-monitoring-forward" "port-forward monitoring Grafana to localhost:3001"
	@printf '    %-66s %s\n' "cluster-up" "create and configure the cluster"
	@printf '    %-66s %s\n' "vm-up" "add the standalone VM backend"
	@printf '    %-66s %s\n' "clean" "remove local build artifacts"
	@echo "  Configuration"
	@echo "    BENCH_CONFIG                         YAML source spec for bench-plan/scenario"
	@echo "    TAG=$(TAG)  TLS_VERSION=$(TLS_VERSION)  TLS_GROUP=$(TLS_GROUP)"
	@echo "    JAVA_TLS_PROVIDER=$(JAVA_TLS_PROVIDER)"
	@echo "    IMAGE_BASE=$(IMAGE_BASE)"
	@echo "    PAYLOAD_PREALLOCATE=$(PAYLOAD_PREALLOCATE)"
	@echo "    TLS_HANDSHAKE_TIMEOUT_SECONDS=$(TLS_HANDSHAKE_TIMEOUT_SECONDS)"
	@echo "    HTTP_REQUEST_TIMEOUT_SECONDS=$(HTTP_REQUEST_TIMEOUT_SECONDS)"
	@echo "    IMPORT_SKIP_WARMUP=$(IMPORT_SKIP_WARMUP)"
	@echo "    ANALYZE_LIST_LIMIT=$(ANALYZE_LIST_LIMIT)"
	@echo "    JUMPBOX_IMAGE=$(JUMPBOX_IMAGE)"
	@echo "    NAMESPACE=$(NAMESPACE)  CLEAN=$(CLEAN)  DOTNET_AOT=$(DOTNET_AOT)"
	@echo "    TOFU_DISPLAY_ARGS=$(TOFU_DISPLAY_ARGS)"

# --- guards ------------------------------------------------------------

.PHONY: guard-scenario
guard-scenario:
	@if [ -z "$(SCENARIO)" ]; then \
	  echo "ERROR: SCENARIO is required. e.g. make $(MAKECMDGOALS) SCENARIO=s2-vm-go"; exit 1; fi
	@echo "$(AVAILABLE_SCENARIOS)" | tr ' ' '\n' | grep -qx "$(SCENARIO)" || { \
	  echo "ERROR: unknown scenario '$(SCENARIO)'"; \
	  echo "valid:"; printf '  %s\n' $(AVAILABLE_SCENARIOS); exit 1; }

.PHONY: guard-scenarios
guard-scenarios:
	@test -n "$(strip $(SCENARIOS))" || { \
	  echo "ERROR: SCENARIOS is required. e.g. make scenarios SCENARIOS=\"s2-vm-net s2-vm-go\" BENCH_CONFIG=bench/simple-http1-tls.yaml TAG=dev"; exit 1; \
	}
	@seen=""; for scenario in $(SCENARIOS); do \
	  case " $$seen " in *" $$scenario "*) \
	    echo "ERROR: duplicate scenario '$$scenario'."; exit 1 ;; \
	  esac; \
	  echo "$(AVAILABLE_SCENARIOS)" | tr ' ' '\n' | grep -qx "$$scenario" || { \
	    echo "ERROR: unknown scenario '$$scenario'"; \
	    echo "valid:"; printf '  %s\n' $(AVAILABLE_SCENARIOS); exit 1; \
	  }; \
	  seen="$$seen $$scenario"; \
	done

.PHONY: guard-k8s-scenario
guard-k8s-scenario: guard-scenario
	@echo "$(K8S_SCENARIOS)" | tr ' ' '\n' | grep -qx "$(SCENARIO)" || { \
	  echo "ERROR: scenario '$(SCENARIO)' is not deployed with the Kubernetes application chart."; \
	  echo "valid Kubernetes application scenarios:"; printf '  %s\n' $(K8S_SCENARIOS); exit 1; }

.PHONY: guard-tofu
guard-tofu:
	@command -v $(TOFU) >/dev/null || { echo "ERROR: '$(TOFU)' not found."; exit 1; }

.PHONY: guard-clean-mode
guard-clean-mode:
	@case "$(CLEAN)" in true|false) ;; *) \
	  echo "ERROR: CLEAN must be true or false."; exit 1;; \
	esac

.PHONY: guard-bench-config
guard-bench-config:
	@test -n "$(BENCH_CONFIG)" || { echo "ERROR: BENCH_CONFIG is required."; exit 1; }
	@test -f "$(BENCH_CONFIG)" || { echo "ERROR: benchmark config '$(BENCH_CONFIG)' does not exist."; exit 1; }

.PHONY: guard-image-base
guard-image-base:
	@case "$(IMAGE_BASE)" in alpine|deb) ;; *) \
	  echo "ERROR: IMAGE_BASE must be alpine or deb."; exit 1;; \
	esac

.PHONY: guard-tag
guard-tag:
	@test "$(origin TAG)" = "command line" || { \
	  echo "ERROR: TAG must be explicit. Use the same tag passed to 'make images', e.g. TAG=dev."; exit 1; \
	}
	@test "$(TAG)" != "latest" || { echo "ERROR: TAG=latest is forbidden."; exit 1; }

.PHONY: guard-tls-config
guard-tls-config:
	@case "$(TLS_VERSION)" in 1.2|1.3) ;; *) \
	  echo "ERROR: TLS_VERSION must be 1.2 or 1.3."; exit 1;; \
	esac
	@case "$(TLS_GROUP)" in P-256|X25519) ;; *) \
	  echo "ERROR: TLS_GROUP must be P-256 or X25519."; exit 1;; \
	esac
	@case "$(JAVA_TLS_PROVIDER)" in boringssl|jdk) ;; *) \
	  echo "ERROR: JAVA_TLS_PROVIDER must be boringssl or jdk."; exit 1;; \
	esac
	@case "$(SCENARIO)" in *java*) \
	  if [ "$(JAVA_TLS_PROVIDER)" = "jdk" ] && [ "$(TLS_GROUP)" = "X25519" ]; then \
	    echo "ERROR: Java JDK/JSSE cannot exact-pin X25519 with the P-256 ECDSA server certificate."; \
	    echo "Use JAVA_TLS_PROVIDER=boringssl for TLS_GROUP=X25519, or use TLS_GROUP=P-256 with JAVA_TLS_PROVIDER=jdk."; \
	    exit 1; \
	  fi; \
	esac
	@if [ "$(SCENARIO)" = "s1-iis-netfx" ] && [ "$(TLS_VERSION)" != "1.2" ]; then \
	  echo "ERROR: s1-iis-netfx supports TLS 1.2 only."; exit 1; \
	fi

.PHONY: guard-vmss
guard-vmss:
	@test -n "$(VMSS)" || { echo "ERROR: VMSS is required. e.g. make reimage VMSS=wtt-perf-client-loadgen-vmss"; exit 1; }

.PHONY: guard-scenario-config
guard-scenario-config: guard-scenario guard-bench-config

# --- infra -------------------------------------------------------------

TF_ARGS = -var active_scenario=$(SCENARIO)
TF_AUTO_APPROVE_FLAG = $(if $(filter true,$(TF_AUTO_APPROVE)),-auto-approve)

CLIENT_TARGETS = \
	-target=azurerm_linux_virtual_machine_scale_set.client_vmss \
	-target=azurerm_role_assignment.client_kv_secrets_user

OUTBOUND_TARGETS = \
	-target=module.network.azurerm_lb_outbound_rule.outbound

K8S_TARGETS = \
	-target=module.acr \
	-target=module.k8s_selfhosted \
	$(CLIENT_TARGETS) \
	$(OUTBOUND_TARGETS)

CLUSTER_ONLY_TARGETS = \
	-target=module.acr \
	-target=module.k8s_selfhosted \
	$(OUTBOUND_TARGETS)

WINDOWS_VM_TARGETS = \
	-target=module.acr \
	-target=module.lb \
	-target=module.vm_windows_iis \
	$(CLIENT_TARGETS) \
	$(OUTBOUND_TARGETS)

LINUX_VM_TARGETS = \
	-target=module.acr \
	-target=module.lb \
	-target=module.vm_linux_app \
	$(CLIENT_TARGETS) \
	$(OUTBOUND_TARGETS)

VM_ONLY_TARGETS = \
	-target=module.acr \
	-target=module.lb \
	-target=module.vm_linux_app \
	$(OUTBOUND_TARGETS)

SCENARIO_TARGETS = $(strip \
	$(if $(filter c0-cluster-only,$(SCENARIO)),$(CLUSTER_ONLY_TARGETS), \
	$(if $(filter c0-vm-only,$(SCENARIO)),$(VM_ONLY_TARGETS), \
	$(if $(filter s1-iis-netfx,$(SCENARIO)),$(WINDOWS_VM_TARGETS), \
	$(if $(filter $(SCENARIO),$(K8S_SCENARIOS)),$(K8S_TARGETS), \
	$(LINUX_VM_TARGETS))))))

TF_SCOPE_ARGS = $(if $(filter true,$(CLEAN)),,$(SCENARIO_TARGETS))

.PHONY: init
init: guard-tofu
	cd $(IAC_DIR) && $(TOFU) init

.PHONY: validate
validate: guard-tofu
	cd $(IAC_DIR) && $(TOFU) init -backend=false >/dev/null && $(TOFU) validate
	$(TOFU) fmt -check -recursive iac/
	@set -e; \
	  $(HELM) dependency build $(APP_CHART); \
	  trap 'rm -f $(APP_CHART)/Chart.lock $(APP_CHART)/charts/workload-*.tgz' EXIT; \
	  for scenario in $(K8S_SCENARIOS); do \
	  $(HELM) lint $(APP_CHART) -f charts/apps/scenarios/$$scenario.yaml \
	    --set global.image.registry=registry.invalid \
	    --set-string global.image.tag=validate || exit $$?; \
	done

.PHONY: plan
plan: guard-tofu guard-scenario guard-clean-mode
	cd $(IAC_DIR) && $(TOFU) plan $(TOFU_DISPLAY_ARGS) $(TF_ARGS) $(TF_SCOPE_ARGS)

.PHONY: apply
apply: guard-tofu guard-scenario guard-clean-mode
	cd $(IAC_DIR) && $(TOFU) apply $(TOFU_DISPLAY_ARGS) $(TF_AUTO_APPROVE_FLAG) $(TF_ARGS) $(TF_SCOPE_ARGS)

.PHONY: destroy
destroy: guard-tofu
	cd $(IAC_DIR) && $(TOFU) destroy

.PHONY: outputs
outputs: guard-tofu
	cd $(IAC_DIR) && $(TOFU) output

# --- images ------------------------------------------------------------

.PHONY: build
build: guard-image-base
	./src/build-images.sh --build-only --tag $(TAG) --dotnet-aot "$(DOTNET_AOT)" --image-base "$(IMAGE_BASE)"

.PHONY: push
push: guard-image-base
	$(MAKE) podman-login
	./src/build-images.sh --tag $(TAG) --registry "$(ACR)" --dotnet-aot "$(DOTNET_AOT)" --image-base "$(IMAGE_BASE)"

.PHONY: images
images: push

.PHONY: podman-login
podman-login: guard-tofu
	@set -e; \
	  registry="$$(cd $(IAC_DIR) && $(TOFU) output -raw acr_login_server)"; \
	  registry_name="$${registry%%.*}"; \
	  token="$$(az acr login --name "$$registry_name" --expose-token --query accessToken --output tsv)"; \
	  printf '%s' "$$token" | podman login "$$registry" \
	    --username 00000000-0000-0000-0000-000000000000 --password-stdin \
	    --authfile "$(ANALYZE_PODMAN_DIR)/auth.json"

.PHONY: oras-login
oras-login: guard-tofu
	@set -e; \
	  registry="$$(cd $(IAC_DIR) && $(TOFU) output -raw acr_login_server)"; \
	  key_vault_name="$$(cd $(IAC_DIR) && $(TOFU) output -raw key_vault_name)"; \
	  docker_config="$$(az keyvault secret show \
	    --vault-name "$$key_vault_name" \
	    --name acr-push-dockerconfigjson \
	    --query value --output tsv)"; \
	  username="$$(jq -er --arg registry "$$registry" '.auths[$$registry].username' <<<"$$docker_config")"; \
	  password="$$(jq -er --arg registry "$$registry" '.auths[$$registry].password' <<<"$$docker_config")"; \
	  printf '%s' "$$password" | oras login "$$registry" --username "$$username" --password-stdin

# --- apps/charts -------------------------------------------------------

.PHONY: charts
charts:
	./charts/fetch-charts.sh

.PHONY: deploy
deploy: guard-scenario guard-tag guard-tls-config
	@if echo "$(K8S_SCENARIOS)" | tr ' ' '\n' | grep -qx "$(SCENARIO)"; then \
	  $(MAKE) deploy-k8s SCENARIO=$(SCENARIO) TAG=$(TAG) TLS_GROUP=$(TLS_GROUP) TLS_VERSION=$(TLS_VERSION) JAVA_TLS_PROVIDER=$(JAVA_TLS_PROVIDER) PAYLOAD_PREALLOCATE=$(PAYLOAD_PREALLOCATE) TLS_HANDSHAKE_TIMEOUT_SECONDS=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) HTTP_REQUEST_TIMEOUT_SECONDS=$(HTTP_REQUEST_TIMEOUT_SECONDS); \
	elif [ "$(SCENARIO)" = "s1-iis-netfx" ]; then \
	  $(MAKE) deploy-windows-vm SCENARIO=$(SCENARIO) TAG=$(TAG) TLS_GROUP=$(TLS_GROUP) TLS_VERSION=$(TLS_VERSION) PAYLOAD_PREALLOCATE=$(PAYLOAD_PREALLOCATE); \
	elif [ "$(SCENARIO)" = "c0-cluster-only" ]; then \
	  echo "No application is deployed for c0-cluster-only."; \
	else \
	  $(MAKE) deploy-linux-vm SCENARIO=$(SCENARIO) TAG=$(TAG) TLS_GROUP=$(TLS_GROUP) TLS_VERSION=$(TLS_VERSION) JAVA_TLS_PROVIDER=$(JAVA_TLS_PROVIDER) PAYLOAD_PREALLOCATE=$(PAYLOAD_PREALLOCATE) TLS_HANDSHAKE_TIMEOUT_SECONDS=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) HTTP_REQUEST_TIMEOUT_SECONDS=$(HTTP_REQUEST_TIMEOUT_SECONDS); \
	fi

.PHONY: deploy-k8s
deploy-k8s: guard-k8s-scenario guard-tls-config cluster-configure
	@test -n "$(ACR)" || { echo "ERROR: no acr_login_server output; run 'make apply' first."; exit 1; }
	@set -e; \
	  legacy_releases="$$($(HELM) list --namespace $(NAMESPACE) --short --filter '^wtt-s')"; \
	  for release in $$legacy_releases; do \
	    echo "Removing legacy workload release $$release..."; \
	    $(HELM) uninstall "$$release" --namespace $(NAMESPACE); \
	  done; \
	  trap 'rm -f $(APP_CHART)/Chart.lock $(APP_CHART)/charts/workload-*.tgz' EXIT; \
	  $(HELM) upgrade --install $(WORKLOAD_RELEASE) $(APP_CHART) \
	    --dependency-update \
	    --namespace $(NAMESPACE) --create-namespace \
	    -f $(K8S_VALUES) \
	    --set global.image.registry=$(ACR) \
	    --set-string global.image.tag=$(TAG) \
	    --set-string workload-go.config.tls.version=$(TLS_VERSION) \
	    --set-string workload-net.config.tls.version=$(TLS_VERSION) \
	    --set-string workload-java.config.tls.version=$(TLS_VERSION) \
	    --set-string workload-rust.config.tls.version=$(TLS_VERSION) \
	    --set-string routing.tlsVersion=$(TLS_VERSION) \
	    --set-string workload-go.config.tls.group=$(TLS_GROUP) \
	    --set-string workload-net.config.tls.group=$(TLS_GROUP) \
	    --set-string workload-java.config.tls.group=$(TLS_GROUP) \
	    --set-string workload-java.config.tls.provider=$(JAVA_TLS_PROVIDER) \
	    --set-string workload-rust.config.tls.group=$(TLS_GROUP) \
	    --set-string routing.tlsGroup=$(TLS_GROUP) \
	    --set workload-go.config.payload.preallocate=$(PAYLOAD_PREALLOCATE) \
	    --set workload-net.config.payload.preallocate=$(PAYLOAD_PREALLOCATE) \
	    --set workload-java.config.payload.preallocate=$(PAYLOAD_PREALLOCATE) \
	    --set workload-rust.config.payload.preallocate=$(PAYLOAD_PREALLOCATE) \
	    --set workload-go.config.timeouts.tlsHandshakeSeconds=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) \
	    --set workload-net.config.timeouts.tlsHandshakeSeconds=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) \
	    --set workload-java.config.timeouts.tlsHandshakeSeconds=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) \
	    --set workload-rust.config.timeouts.tlsHandshakeSeconds=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) \
	    --set workload-go.config.timeouts.httpRequestSeconds=$(HTTP_REQUEST_TIMEOUT_SECONDS) \
	    --set workload-net.config.timeouts.httpRequestSeconds=$(HTTP_REQUEST_TIMEOUT_SECONDS) \
	    --set workload-java.config.timeouts.httpRequestSeconds=$(HTTP_REQUEST_TIMEOUT_SECONDS) \
	    --set workload-rust.config.timeouts.httpRequestSeconds=$(HTTP_REQUEST_TIMEOUT_SECONDS) \
	    --wait

.PHONY: deploy-linux-vm
deploy-linux-vm: guard-scenario guard-tag guard-tls-config
	@set -e; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  vmss_name="$$(cd $(IAC_DIR) && $(TOFU) output -raw linux_app_vmss_name)"; \
	  test -n "$$vmss_name" || { echo "ERROR: Linux application VMSS is not deployed."; exit 1; }; \
	  case "$(SCENARIO)" in \
	    s2-vm-net|c2-vm-net-plain) repository="net10-server" ;; \
	    s2-vm-java|c2-vm-java-plain) repository="java-netty-server" ;; \
	    s2-vm-rust|c2-vm-rust-plain) repository="rust-server" ;; \
	    s2-vm-go|c2-vm-go-plain|c0-vm-only) repository="go-server" ;; \
	    *) echo "ERROR: $(SCENARIO) is not a Linux VM scenario."; exit 1 ;; \
	  esac; \
	  case "$(SCENARIO)" in c2-*|c3-*) tls_enabled=false ;; *) tls_enabled=true ;; esac; \
	  ./scripts/deploy-linux-app.sh \
	    "$$resource_group" "$$vmss_name" "$(ACR)/wtt/$$repository:$(TAG)" \
	    "$$tls_enabled" "$(TLS_VERSION)" "$(PAYLOAD_PREALLOCATE)" \
	    "$(TLS_HANDSHAKE_TIMEOUT_SECONDS)" "$(HTTP_REQUEST_TIMEOUT_SECONDS)" "$(TLS_GROUP)" \
	    "$(JAVA_TLS_PROVIDER)"

.PHONY: deploy-windows-vm
deploy-windows-vm: guard-tls-config
	@set -e; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  vmss_name="$$(cd $(IAC_DIR) && $(TOFU) output -raw windows_iis_vmss_name)"; \
	  key_vault_name="$$(cd $(IAC_DIR) && $(TOFU) output -raw key_vault_name)"; \
	  test -n "$$vmss_name" || { echo "ERROR: Windows IIS VMSS is not deployed."; exit 1; }; \
	  ./src/netfx48-server/publish-artifact.sh "$(ACR)" "$(TAG)"; \
	  ./scripts/deploy-windows-iis.sh \
	    "$$resource_group" "$$vmss_name" "$(ACR)" "$(TAG)" \
	    "$$key_vault_name" "$(TLS_VERSION)" "$(PAYLOAD_PREALLOCATE)" "$(TLS_GROUP)"

# --- bench --------------------------------------------------------------

.PHONY: bench-plan
bench-plan: guard-scenario-config
	SCENARIO="$(SCENARIO)" ./scripts/bench-prepare.sh "$(BENCH_CONFIG)"

.PHONY: bench
bench: guard-scenario-config
	$(MAKE) bench-run SCENARIO=$(SCENARIO) BENCH_CONFIG=$(BENCH_CONFIG) BENCH_RUN_CONFIG=$(BENCH_RUN_CONFIG)
	$(MAKE) bench-status BENCH_RUN_CONFIG=$(BENCH_RUN_CONFIG)
# 	$(MAKE) bench-get BENCH_RUN_CONFIG=$(BENCH_RUN_CONFIG)

.PHONY: bench-run
bench-run: guard-scenario-config
	@mkdir -p "$(dir $(BENCH_RUN_CONFIG))"
	@SCENARIO="$(SCENARIO)" ./scripts/bench-prepare.sh "$(BENCH_CONFIG)" > "$(BENCH_RUN_CONFIG)"
	./scripts/bench-run.sh "$(BENCH_RUN_CONFIG)"

.PHONY: bench-status
bench-status:
	@test -f "$(BENCH_RUN_CONFIG)" || { echo "ERROR: resolved benchmark config '$(BENCH_RUN_CONFIG)' does not exist. Run 'make bench-run' first."; exit 1; }
	./scripts/bench-status.sh "$(BENCH_RUN_CONFIG)"

.PHONY: bench-get
bench-get:
	@test -f "$(BENCH_RUN_CONFIG)" || { echo "ERROR: resolved benchmark config '$(BENCH_RUN_CONFIG)' does not exist. Run 'make bench-run' first."; exit 1; }
	./scripts/bench-get.sh "$(BENCH_RUN_CONFIG)"

.PHONY: scenario
scenario: guard-scenario-config guard-tag
	$(MAKE) apply SCENARIO=$(SCENARIO) TF_AUTO_APPROVE=true
 	$(MAKE) images TAG=$(TAG) IMAGE_BASE=$(IMAGE_BASE) DOTNET_AOT=$(DOTNET_AOT)
	$(MAKE) deploy SCENARIO=$(SCENARIO) TAG=$(TAG) TLS_GROUP=$(TLS_GROUP) TLS_VERSION=$(TLS_VERSION) JAVA_TLS_PROVIDER=$(JAVA_TLS_PROVIDER) PAYLOAD_PREALLOCATE=$(PAYLOAD_PREALLOCATE) TLS_HANDSHAKE_TIMEOUT_SECONDS=$(TLS_HANDSHAKE_TIMEOUT_SECONDS) HTTP_REQUEST_TIMEOUT_SECONDS=$(HTTP_REQUEST_TIMEOUT_SECONDS)
	$(MAKE) bench SCENARIO=$(SCENARIO) BENCH_CONFIG=$(BENCH_CONFIG) BENCH_RUN_CONFIG=$(BENCH_RUN_CONFIG) TLS_GROUP=$(TLS_GROUP) TLS_VERSION=$(TLS_VERSION) JAVA_TLS_PROVIDER=$(JAVA_TLS_PROVIDER)
	@echo "done: $(SCENARIO)"

.PHONY: scenarios
scenarios: guard-scenarios guard-bench-config guard-tag
	@set -e; \
	  for scenario in $(SCENARIOS); do \
	    echo "WTT_SCENARIO_START=$$scenario"; \
	    $(MAKE) scenario SCENARIO="$$scenario" BENCH_CONFIG="$(BENCH_CONFIG)" TAG="$(TAG)" TLS_GROUP="$(TLS_GROUP)" TLS_VERSION="$(TLS_VERSION)" JAVA_TLS_PROVIDER="$(JAVA_TLS_PROVIDER)" IMAGE_BASE="$(IMAGE_BASE)" DOTNET_AOT="$(DOTNET_AOT)" PAYLOAD_PREALLOCATE="$(PAYLOAD_PREALLOCATE)" TLS_HANDSHAKE_TIMEOUT_SECONDS="$(TLS_HANDSHAKE_TIMEOUT_SECONDS)" HTTP_REQUEST_TIMEOUT_SECONDS="$(HTTP_REQUEST_TIMEOUT_SECONDS)" BENCH_RUN_CONFIG="$(BENCH_RUN_CONFIG)"; \
	    echo "WTT_SCENARIO_COMPLETE=$$scenario"; \
	  done

# Offline result analysis
.PHONY: analyze-up
analyze-up:
	podman compose --env-file $(ANALYZE_PODMAN_DIR)/.env -f $(ANALYZE_PODMAN_DIR)/compose.yaml up -d

.PHONY: analyze-up-oci
analyze-up-oci: podman-login
	@test -r "$(ANALYZE_PODMAN_DIR)/auth.json" || { \
	  echo "ERROR: run 'make podman-login' before importing an OCI artifact."; exit 1; \
	}
	podman compose --env-file $(ANALYZE_PODMAN_DIR)/.env \
	  -f $(ANALYZE_PODMAN_DIR)/compose.yaml \
	  -f $(ANALYZE_PODMAN_DIR)/compose.oci.yaml \
	  up -d

.PHONY: analyze-down
analyze-down:
	podman compose --env-file $(ANALYZE_PODMAN_DIR)/.env -f $(ANALYZE_PODMAN_DIR)/compose.yaml down

.PHONY: analyze-get
analyze-get: podman-login
	@test -n "$(ARTIFACT_IMAGES)" || { echo "ERROR: ARTIFACT_IMAGES is required."; exit 1; }
	@artifact_images=(); \
	  read -r -a artifact_images <<< "$(ARTIFACT_IMAGES)"; \
	  ./scripts/analyze-get.sh "$${artifact_images[@]}"

.PHONY: analyze-list
analyze-list: guard-tofu
	@case "$(ANALYZE_LIST_LIMIT)" in \
	  ''|*[!0-9]*) echo "ERROR: ANALYZE_LIST_LIMIT must be a positive integer."; exit 1 ;; \
	  0) echo "ERROR: ANALYZE_LIST_LIMIT must be greater than zero."; exit 1 ;; \
	esac
	@set -e; \
	  registry="$$(cd $(IAC_DIR) && $(TOFU) output -raw acr_login_server)"; \
	  registry_name="$${registry%%.*}"; \
	  tags="$$(az acr repository show-tags --name "$$registry_name" \
	    --repository wtt/benchmark-results --orderby time_desc \
	    --top "$(ANALYZE_LIST_LIMIT)" --output tsv)"; \
	  if [ -z "$$tags" ]; then \
	    echo "No benchmark-result OCI artifacts found in $$registry/wtt/benchmark-results."; \
	    exit 0; \
	  fi; \
	  printf '%s\n' "$$tags" | while IFS= read -r tag; do \
	    printf '%s/wtt/benchmark-results:%s\n' "$$registry" "$$tag"; \
	  done

.PHONY: analyze-pod
analyze-pod:
	@set -e; \
	  artifact_args=(); \
	  skip_warmup="$(IMPORT_SKIP_WARMUP)"; \
	  case "$$skip_warmup" in true|false) ;; *) echo "ERROR: IMPORT_SKIP_WARMUP must be true or false."; exit 1 ;; esac; \
	  importer_args=(--set "importer.skipWarmup=$$skip_warmup"); \
	  if [ -n "$(IMPORT_ARTIFACT_IMAGES)" ]; then \
	    artifact_values="$$(printf '%s\n' "$(IMPORT_ARTIFACT_IMAGES)" | tr ' ' '\n' | jq -R . | jq -sc .)"; \
	    artifact_args=(--set-string importer.source.resultsDir= --set-json "importer.source.artifacts=$$artifact_values"); \
	  fi; \
	  $(HELM) upgrade --install $(ANALYZE_RELEASE) $(ANALYZE_CHART_DIR) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --set-file files.influxdb=$(ANALYZE_DIR)/files/influxdb.yaml \
	  --set-file files.dashboard=$(ANALYZE_DIR)/files/dashboard.yaml \
	  --set-file files.liveDashboardJson=$(ANALYZE_DIR)/dashboards/k6-live.json \
	  --set-file files.comparisonDashboardJson=$(ANALYZE_DIR)/dashboards/k6-comparison.json \
	  --set-file files.comparisonAcrossProfilesDashboardJson=$(ANALYZE_DIR)/dashboards/k6-comparison-across-profiles.json \
	  --set-file files.comparisonRunTimelineDashboardJson=$(ANALYZE_DIR)/dashboards/k6-comparison-run-timeline.json \
	  --set-file files.comparisonRunTimelineAcrossProfileRunsDashboardJson=$(ANALYZE_DIR)/dashboards/k6-comparison-run-timeline-across-profile-runs.json \
	  --set-file files.runCatalogDashboardJson=$(ANALYZE_DIR)/dashboards/k6-run-catalog.json \
	  --set-file files.importerScript=$(ANALYZE_DIR)/files/import-results.sh \
	  --set-file files.importerPython=$(ANALYZE_DIR)/files/import-results.py \
	  "$${artifact_args[@]}" "$${importer_args[@]}"

.PHONY: analyze-forward
analyze-forward:
	kubectl -n $(NAMESPACE) port-forward deployment/$(ANALYZE_RELEASE) 3000:3000

.PHONY: analyze-influx-forward
analyze-influx-forward:
	kubectl -n $(NAMESPACE) port-forward deployment/$(ANALYZE_RELEASE) 8086:8086

# --- debug --------------------------------------------------------------

.PHONY: jumpbox
jumpbox: guard-tofu
	@set -e; \
	  cd $(IAC_DIR); \
	  $(TOFU) apply -auto-approve \
	    -var client_jumpbox_enabled=true \
	    -var client_jumpbox_image="$(JUMPBOX_IMAGE)" \
	    -target=module.acr \
	    -target=module.network.azurerm_subnet.client_jumpbox; \
	  registry_name="$$($(TOFU) output -raw acr_registry_name)"; \
	  az acr import --name "$$registry_name" \
	    --source "docker.io/library/$(JUMPBOX_IMAGE)" \
	    --image "wtt/$(JUMPBOX_IMAGE)" --force; \
	  $(TOFU) apply -auto-approve \
	    -var client_jumpbox_enabled=true \
	    -var client_jumpbox_image="$(JUMPBOX_IMAGE)" \
	    -target=azurerm_container_group.client_jumpbox

.PHONY: jump
jump: guard-tofu
	@set -e; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  jumpbox_name="$$(cd $(IAC_DIR) && $(TOFU) output -raw client_jumpbox_name)"; \
	  test -n "$$jumpbox_name" && test "$$jumpbox_name" != "null" || \
	    { echo "ERROR: jumpbox is not provisioned; run 'make jumpbox' first."; exit 1; }; \
	  az container exec \
	    --resource-group "$$resource_group" \
	    --name "$$jumpbox_name" \
	    --container-name jumpbox \
	    --exec-command /bin/sh

# Reimage every instance in the named VMSS pool.
.PHONY: vmss-reimage
vmss-reimage: guard-tofu guard-vmss
	@resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  az vmss reimage --resource-group "$$resource_group" --name "$(VMSS)"

# Reimage all managed disks for every instance in the named VMSS pool.
.PHONY: vmss-reimagefull
vmss-reimagefull: guard-tofu guard-vmss
	@resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  subscription_id="$$(az account show --query id --output tsv)"; \
	  az rest --method post \
	    --url "https://management.azure.com/subscriptions/$$subscription_id/resourceGroups/$$resource_group/providers/Microsoft.Compute/virtualMachineScaleSets/$(VMSS)/reimageall?api-version=2026-04-01"

# Full reimage across every deployed benchmark VMSS pool.
.PHONY: vmss-reimageall
vmss-reimageall: guard-tofu
	@set -e; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  control_plane_vmss="$$(cd $(IAC_DIR) && $(TOFU) output -raw control_plane_vmss_name 2>/dev/null || true)"; \
	  vmss_names="$$(az vmss list --resource-group "$$resource_group" \
	    --query "[?starts_with(name, 'wtt-perf-')].name" --output tsv)"; \
	  test -n "$$vmss_names" || { echo "ERROR: no benchmark VMSS pools are deployed."; exit 1; }; \
	  for vmss_name in $$vmss_names; do \
	    if [ "$$vmss_name" = "$$control_plane_vmss" ]; then target=vmss-reimagefull; else target=vmss-reimage; fi; \
	    printf '%s\0VMSS=%s\0' "$$target" "$$vmss_name"; \
	  done | xargs -0 -r -n 2 -P 0 $(MAKE)

.PHONY: vmss-startall
vmss-startall: guard-tofu
	@set -e; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  vmss_names="$$(az vmss list --resource-group "$$resource_group" \
	    --query "[?starts_with(name, 'wtt-perf-')].name" --output tsv)"; \
	  test -n "$$vmss_names" || { echo "ERROR: no benchmark VMSS pools are deployed."; exit 1; }; \
	  for vmss_name in $$vmss_names; do \
	    printf '%s\0' "$$vmss_name"; \
	  done | xargs -0 -r -n 1 -P 0 az vmss start --resource-group "$$resource_group" --name

.PHONY: vmss-stopall
vmss-stopall: guard-tofu
	@set -e; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  vmss_names="$$(az vmss list --resource-group "$$resource_group" \
	    --query "[?starts_with(name, 'wtt-perf-')].name" --output tsv)"; \
	  test -n "$$vmss_names" || { echo "ERROR: no benchmark VMSS pools are deployed."; exit 1; }; \
	  for vmss_name in $$vmss_names; do \
	    printf '%s\0' "$$vmss_name"; \
	  done | xargs -0 -r -n 1 -P 0 az vmss deallocate --resource-group "$$resource_group" --name

.PHONY: cluster-create
cluster-create:
	$(MAKE) apply SCENARIO=c0-cluster-only
	@echo ""
	@echo "Cluster created. Nodes are EXPECTED to be NotReady until the CNI is"
	@echo "installed -- run 'make cluster-configure' next."

.PHONY: cluster-configure
cluster-configure:
	bash ./scripts/configure-cluster.sh \
		results/kubeconfig \
		./scripts/get-control-plane-ip.sh

.PHONY: cluster-monitoring
cluster-monitoring:
	@test -d charts/vendor/kube-prometheus-stack || { \
	  echo "ERROR: monitoring chart is unavailable; run 'make charts' first."; exit 1; }
	@test -d charts/vendor/pyroscope || { \
	  echo "ERROR: Pyroscope chart is unavailable; run 'make charts' first."; exit 1; }
	$(HELM) --kubeconfig $(KUBECONFIG) upgrade --install $(MONITORING_RELEASE) charts/vendor/kube-prometheus-stack \
	  --namespace $(MONITORING_NAMESPACE) --create-namespace \
	  --values charts/vendor/kube-prometheus-stack.yaml
	$(HELM) --kubeconfig $(KUBECONFIG) upgrade --install $(PYROSCOPE_RELEASE) charts/vendor/pyroscope \
	  --namespace $(MONITORING_NAMESPACE) --create-namespace \
	  --values charts/vendor/pyroscope-values.yaml

.PHONY: cluster-monitoring-forward
cluster-monitoring-forward:
	kubectl --kubeconfig $(KUBECONFIG) --namespace $(MONITORING_NAMESPACE) \
	  port-forward service/$(MONITORING_RELEASE)-grafana 3001:80

.PHONY: cluster-up
cluster-up: cluster-create cluster-configure

.PHONY: vm-up
vm-up:
	$(MAKE) apply SCENARIO=c0-vm-only

# Run kubectl on control-plane VMSS instance 0 through Azure Run Command.
# This is a fallback when the operator cannot reach the cluster directly.
# Usage: make kubectl CMD="get nodes -o wide"
.PHONY: kubectl
kubectl: guard-tofu
	@set -e; \
	  test -n "$(CMD)" || { echo "ERROR: CMD is required. e.g. make kubectl CMD=\"get nodes -o wide\""; exit 1; }; \
	  resource_group="$$(cd $(IAC_DIR) && $(TOFU) output -raw resource_group_name)"; \
	  vmss_name="$$(cd $(IAC_DIR) && $(TOFU) output -raw control_plane_vmss_name)"; \
	  test -n "$$vmss_name" && test "$$vmss_name" != "null" || \
	    { echo "ERROR: control-plane VMSS is not provisioned."; exit 1; }; \
	  az vmss run-command invoke \
	    --resource-group "$$resource_group" \
	    --name "$$vmss_name" \
	    --instance-id 0 \
	    --command-id RunShellScript \
	    --scripts "kubectl $(CMD)" \
	    --query 'value[].message' \
	    --output tsv

.PHONY: kubeconfig
kubeconfig: guard-tofu
	@cd $(IAC_DIR) && $(TOFU) output -raw kubeconfig_path 2>/dev/null \
	  || { echo "ERROR: no kubeconfig output. Run 'make cluster-create' first."; exit 1; }
	@echo "export KUBECONFIG=$(CURDIR)/results/kubeconfig"

.PHONY: clean
clean:
	rm -rf src/go-server/bin src/dotnet10-server/bin src/dotnet10-server/obj src/dotnet11-server/bin src/dotnet11-server/obj src/java-netty-server/target
