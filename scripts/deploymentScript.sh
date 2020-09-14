#!/bin/bash

## THIS SCRIPT WILL CONFIGURE THE OCP CLUSTER AND BIG-IP TO PREPARE FOR CIS INTEGRATION VIA VXLAN OVERLAY
BIGIP_INT_SELFIP=$1
ARO_API_SERVER=$2
ARO_KUBE_ADMIN=$3
ARO_PASSWORD=$4
BIGIP_MGMT_PUBLIC_IP=$5
BIGIP_MGMT_PRIVATE_IP=$6
BIGIP_MGMT_USERNAME=$7
BIGIP_MGMT_PASSWORD=$8

##Download OC client tool
wget https://raw.githubusercontent.com/mikeoleary/azure-redhat-openshift-f5/main/client/openshift-client-linux.tar.gz -O /tmp/openshift-client-linux.tar.gz
tar -xf /tmp/openshift-client-linux.tar.gz -C /tmp
mv /tmp/oc /usr/local/bin -f
mv /tmp/kubectl /usr/local/bin -f

##Download and edit yaml file template for hostsubnet, then apply new hostsubnet
wget https://raw.githubusercontent.com/mikeoleary/azure-redhat-openshift-f5/main/templates/f5-bigip-node01.yaml  -O /tmp/f5-bigip-node01.yaml
sed -i -e "s/INTERNALSELFIP/$BIGIP_INT_SELFIP/" /tmp/f5-bigip-node01.yaml
oc login $ARO_API_SERVER -u=$ARO_KUBE_ADMIN -p=$ARO_PASSWORD
oc apply -f /tmp/f5-bigip-node01.yaml

#get cluster network mask. This is usually /14
CLUSTERNETWORK=$(oc get clusternetwork -o json | jq .items[0].network -r)
read -a strarr <<< $(echo $CLUSTERNETWORK | tr "/" " ")
CLUSTERNETWORK_MASK=${strarr[1]}

#Calculate a self IP for tunnel on BIGIP. First get assigned host subnet, which is usually a /23 range like 10.130.2.0/23. We will assign .100 from this range, eg, 10.130.2.100
BIGIP_HOST_SUBNET_WITH_MASK=$(oc get hostsubnet f5-bigip-node01 -o json | jq .subnet -r)
read -a strarr <<< $(echo $BIGIP_HOST_SUBNET_WITH_MASK | tr "/" " ")
BIGIP_HOST_SUBNET=${strarr[0]}
BIGIP_TUNNEL_SELFIP="${BIGIP_HOST_SUBNET%.*}.100/$CLUSTERNETWORK_MASK"

###Connect to BIG-IP and create tunnel profile, tunnel, selfIP on tunnel, and add vxlan port 4789 to internal self IP
#Create multipoint vxlan profile
curl -s -k -X POST -H "Content-Type: application/json" -u $BIGIP_MGMT_USERNAME:$BIGIP_MGMT_PASSWORD https://$BIGIP_MGMT_PUBLIC_IP/mgmt/tm/net/tunnels/vxlan -d '{"name": "vxlan-mp", "floodingType": "multipoint" }'
#Create vxlan tunnel based on vxlan profile
curl -s -k -X POST -H "Content-Type: application/json" -u $BIGIP_MGMT_USERNAME:$BIGIP_MGMT_PASSWORD https://$BIGIP_MGMT_PUBLIC_IP/mgmt/tm/net/tunnels/tunnel -d '{"name": "openshift_vxlan", "key": "0", "profile": "vxlan-mp", "localAddress": "'"$BIGIP_INT_SELFIP"'" }'
#Create selfIP on tunnel
curl -s -k -X POST -H "Content-Type: application/json" -u $BIGIP_MGMT_USERNAME:$BIGIP_MGMT_PASSWORD https://$BIGIP_MGMT_PUBLIC_IP/mgmt/tm/net/self -d '{"name": "tunnelSelfIP", "address": "'"$BIGIP_TUNNEL_SELFIP"'", "vlan": "openshift_vxlan", "profile": "vxlan-mp", "localAddress": "'"$BIGIP_INT_SELFIP"'", "allowService": "all" }'
#set allowed services on selfIP of Internal VLAN to be default + tcp:4789
curl -s -k -X PATCH -H "Content-Type: application/json" -u $BIGIP_MGMT_USERNAME:$BIGIP_MGMT_PASSWORD https://$BIGIP_MGMT_PUBLIC_IP/mgmt/tm/net/self/self_3nic -d '{"allowService": ["default","tcp:4789"]}'

##Deploy F5 CIS
rm -r /tmp/cis -f
mkdir /tmp/cis
wget https://raw.githubusercontent.com/mikeoleary/azure-redhat-openshift-f5/main/cis/cis.yaml /tmp/cis
sed -i -e "s/<base64password>/$BIGIP_MGMT_PASSWORD/" /tmp/cis/cis.yaml
sed -i -e "s/<bigipUrl>/$BIGIP_MGMT_PRIVATE_IP/" /tmp/cis/cis.yaml
oc apply -f /tmp/cis.yaml
