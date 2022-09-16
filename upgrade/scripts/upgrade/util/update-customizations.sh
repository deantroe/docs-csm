#!/usr/bin/env bash
#
# MIT License
#
# (C) Copyright 2021-2022 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

set -e
basedirLoc=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
. ${basedirLoc}/../../common/upgrade-state.sh
trap 'err_report' ERR
set -o pipefail

usage() {
    echo >&2 "usage: ${0##*/} [-i] [CUSTOMIZATIONS-YAML]"
    exit 1
}

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h)
            usage
            ;;
        -i)
            inplace="yes"
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift
done

set -- "${args[@]}"

[[ $# -eq 1 ]] || usage


customizations="$1"

if [[ ! -f "$customizations" ]]; then
    echo >&2 "error: no such file: $customizations"
    usage
fi

if ! command -v yq &> /dev/null
then
    echo >&2 "error: yq could not be found"
    exit 1
fi

c="$(mktemp)"
trap 'rm -f $c' EXIT

cp "$customizations" "$c"

# argo/cray-nls
yq w -i --style=single "$c" spec.kubernetes.services.cray-nls.externalHostname 'cmn.{{ network.dns.external }}'

if [[ -z "$(yq r "$c" 'spec.proxiedWebAppExternalHostnames.customerManagement(.==argo.cmn.{{ network.dns.external }})')" ]];then
   yq w -i --style=single "$c" spec.proxiedWebAppExternalHostnames.customerManagement[+] 'argo.cmn.{{ network.dns.external }}'
fi

# cray-opa
yq w -i "$c" 'spec.kubernetes.services.cray-opa.ingresses.ingressgateway-hmn.issuers.shasta-hmn' 'https://api.hmnlb.{{ network.dns.external }}/keycloak/realms/shasta'
yq w -i "$c" 'spec.kubernetes.services.cray-opa.ingresses.ingressgateway-hmn.issuers.keycloak-hmn' 'https://auth.hmnlb.{{ network.dns.external }}/keycloak/realms/shasta'

# cray-istio
yq w -i "$c" 'spec.kubernetes.services.cray-istio.services.istio-ingressgateway-hmn.serviceAnnotations.[external-dns.alpha.kubernetes.io/hostname]' 'api.hmnlb.{{ network.dns.external }},auth.hmnlb.{{ network.dns.external }},hmcollector.hmnlb.{{ network.dns.external }}'

#
# Add new nmn_ncn_storage_mons values that would be generated by CSI on
# a fresh install.  This list is the first three storage nodes which
# are meant to be endpoints for the cephExporter -- which should run
# on ceph nodes with the mgr daemon running.
#
if [[ -z "$(yq r "$c" "spec.network.netstaticips.nmn_ncn_storage_mons")" ]]; then
  yq w -i $c 'spec.network.netstaticips.nmn_ncn_storage_mons'
  mon_nodes=$(yq r $c 'spec.network.netstaticips.nmn_ncn_storage' | head -3 | awk '{print $2}')
  loop_idx=0
  for node in ${mon_nodes}; do
    yq w -i $c "spec.network.netstaticips.nmn_ncn_storage_mons[${loop_idx}]" "${node}"
    loop_idx=$(( loop_idx+1 ))
  done
  yq w -i --style=single "$c" spec.kubernetes.services.cray-sysmgmt-health.cephExporter.endpoints '{{ network.netstaticips.nmn_ncn_storage_mons }}'
fi
if [[ "$(yq r "$c" "spec.kubernetes.services.cray-sysmgmt-health.prometheus-snmp-exporter.serviceMonitor.enabled")" ]]; then
    idx=0
    temp=1
    mon_node=$(yq r "$c" 'spec.kubernetes.services.cray-sysmgmt-health.prometheus-snmp-exporter.serviceMonitor.params.conf.target' | awk '{print $2}')
    for node in ${mon_node}; do
      yq w -i "$c" "spec.kubernetes.services.cray-sysmgmt-health.prometheus-snmp-exporter.serviceMonitor.params[${idx}].name" "snmp$temp"
      yq w -i "$c" "spec.kubernetes.services.cray-sysmgmt-health.prometheus-snmp-exporter.serviceMonitor.params[${idx}].target" "${node}"
      idx=$(( idx+1 ))
      temp=$(( temp+1 ))
    done
fi
if [[ "$inplace" == "yes" ]]; then
    cp "$c" "$customizations"
else
    cat "$c"
fi
