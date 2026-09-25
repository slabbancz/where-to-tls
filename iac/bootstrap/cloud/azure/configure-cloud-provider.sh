#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env
mkdir -p /etc/kubernetes

jq -n \
  --arg tenantId "${AZURE_TENANT_ID}" \
  --arg subscriptionId "${AZURE_SUBSCRIPTION_ID}" \
  --arg resourceGroup "${AZURE_RESOURCE_GROUP}" \
  --arg location "${AZURE_LOCATION}" \
  --arg vnetName "${AZURE_VNET_NAME}" \
  --arg subnetName "${AZURE_SUBNET_NAME}" \
  --arg securityGroupName "${AZURE_SECURITY_GROUP_NAME}" \
  --arg zone "${AZURE_ZONE}" \
  '{
    cloud: "AzurePublicCloud",
    tenantId: $tenantId,
    subscriptionId: $subscriptionId,
    resourceGroup: $resourceGroup,
    location: $location,
    vnetName: $vnetName,
    vnetResourceGroup: $resourceGroup,
    subnetName: $subnetName,
    securityGroupName: $securityGroupName,
    routeTableName: "",
    primaryAvailabilityZone: $zone,
    vmType: "vmss",
    useManagedIdentityExtension: true,
    useInstanceMetadata: true,
    loadBalancerSku: "standard",
    loadBalancerBackendPoolConfigurationType: "nodeIP",
    disableOutboundSNAT: true
  }' > /etc/kubernetes/azure.json
