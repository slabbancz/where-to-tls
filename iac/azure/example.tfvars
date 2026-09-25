# example.tfvars — Template for iac/azure/terraform.tfvars
# Copy to terraform.tfvars (which is gitignored) and supply valid Azure subscription credentials.
# Never commit real credentials or subscription IDs.

subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "00000000-0000-0000-0000-000000000000"

location          = "northeurope"
env               = "perf"
availability_zone = "3"
server_vm_size    = "Standard_D4s_v7"
client_vm_size    = "Standard_D4s_v7"
# Total primary-NIC source IPv4 pools for k6; raise as needed while subnet capacity permits.
client_source_ip_count = 4

# Active scenario to deploy (Contract §1):
# s1-iis-netfx | s2-vm-net | s2-vm-java | s2-vm-go |
# s4-k8s-pod-net | s4-k8s-pod-go |
# s5-traefik-passthrough-net | s5-traefik-passthrough-go |
# s6-traefik-terminate-net | s6-traefik-terminate-go |
# c2-vm-net-plain | c2-vm-java-plain | c2-vm-go-plain | c4-k8s-pod-net-plain | c4-k8s-pod-go-plain
active_scenario = "s2-vm-net"

dns_zone       = "wtt.local"
admin_username = "azureuser"
