#!/bin/bash

SNABB_BASE=../../../..
TEST_BASE=${SNABB_BASE}/tests/apps/lwaftr/data
TEST_OUT=/tmp

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

function quit_with_msg {
   echo $1; exit 1
}

function snabb_run_and_cmp {
   rm -f ${TEST_OUT}/endout.pcap
   ${SNABB_BASE}/src/snabb snsh ${SNABB_BASE}/src/apps/lwaftr/main.lua \
    $1 $2 ${TEST_OUT}/endout.pcap  || quit_with_msg "Snabb failed"
   echo "cmp $3"; ls -lh $3 ${TEST_OUT}/endout.pcap
   cmp $3 ${TEST_OUT}/endout.pcap || \
      quit_with_err "snabb snsh apps/lwaftr/main.lua $1 $2 $3"
}

echo "Testing with a from-internet IPv4 packet found in the binding table."
snabb_run_and_cmp ${TEST_BASE}/icmp_on_fail.conf \
   ${TEST_BASE}/tcp-frominet-bound.pcap ${TEST_BASE}/tcp-afteraftr-ipv6.pcap


echo "Testing with a from-internet IPv4 packet NOT found in the binding table."
snabb_run_and_cmp ${TEST_BASE}/no_icmp.conf \
   ${TEST_BASE}/tcp-frominet-unbound.pcap ${TEST_BASE}/empty.pcap

# TODO: change the conf and test the ICMP reply to the above

echo "Testing with a from-b4 IPv6 packet NOT found in the binding table."
snabb_run_and_cmp ${TEST_BASE}/no_icmp.conf \
   ${TEST_BASE}/tcp-afteraftr-ipv6.pcap ${TEST_BASE}/empty.pcap

echo "All end-to-end lwAFTR tests passed."
