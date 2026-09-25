# Bootstrap layout

| Directory | Runs on | Contents |
| --- | --- | --- |
| `../../scripts/` | Operator host | Azure CLI, deployment, benchmark orchestration, and cluster configuration helpers. |
| `local/` | Terraform local-exec | OpenTofu helper scripts executed from the operator host. |
| `cloud-init/` | Cloud-init | Templates that place and start node scripts on newly created Linux VMSS instances. |
| `node/` | VMSS node | Linux/Windows host setup, standalone application deployment, and client benchmark execution. |
| `k8s/` | Kubernetes node | Control-plane and worker bootstrap scripts. |
| `cloud/azure/` | Azure VMSS node | Azure IMDS, Key Vault, ACR, and cloud-provider helpers executed from cloud-init or Run Command. |

`scripts/` and `local/` must not be embedded in cloud-init. `cloud/` scripts must not
depend on tools or credentials available only on the operator host.
