#!/usr/bin/env bash

#
#  Licensed to the Apache Software Foundation (ASF) under one
#  or more contributor license agreements.  See the NOTICE file
#  distributed with this work for additional information
#  regarding copyright ownership.  The ASF licenses this file
#  to you under the Apache License, Version 2.0 (the
#  "License"); you may not use this file except in compliance
#  with the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing,
#  software distributed under the License is distributed on an
#  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
#  KIND, either express or implied.  See the License for the
#  specific language governing permissions and limitations
#  under the License.
#

usage() {
    cat <<EOF
fsgen.sh
    
This is a script designed to generate and install a new HDFS fsimage using the
fsgen programmatic image generation tool.  It is designed to run on the
NameNode machine in the cluster.  

Environment variables:
DATANODES        A whitespace-separated list of datanode hostnames.
STORAGE_DIRS     A whitespace-separated list of datanode storage directories.
SSH_USER         The username to use for ssh (leave unset for no username)
SSH_PASS         The password to use for ssh (leave unset for no password)

Possible actions:
-h, --help        Print this usage message

check             Run some self-tests.  In particular, check that we can ssh to
                  all datanodes.

format_dn         Format the datanode storage directories, under /dfs/dnXX.
                  Clear all existing data.

load_fsgen_nn     Load an fsimage prepared by the fsgen program into the
                  namenode's storage directory.  The directory containing the
                  fsgen output should be the first argument.  It's assumed that
                  you only have one storage directory.

load_fsgen_dn     Load an fsimage prepared by the fsgen program into the
                  datanodes' storage directories.  The directory containing the
                  fsgen output should be the first argument.

load_fsgen_dns    Load all fsimage datanodes.

load_fsgen_dns_par Load all fsimage datanodes in parallel.
EOF
exit 0
}

die() {
    echo $@
    exit 1
}

try() {
    $@ || die "command failed: $@"
}

try_verbose() {
    echo "** running $@"
    $@ || die "command failed: $@"
}

check_tool_installed() {
    TOOL=${1}
    which "${TOOL}" &> /dev/null || \
        die "Failed to locate $TOOL: did you install it and make it available on the path?"
}

verify_environment() {
    [ "x${DATANODES}" == "x" ] && \
        die "You must set DATANODES to a whitespace-separated list of datanode hostnames."
    [ "x${STORAGE_DIRS}" == "x" ] && \
        die "You must set STORAGE_DIRS to a whitespace-separated list of datanode hostnames."
    if [ "x$SSH_PASS" != "x" ]; then
        # If we need to specify an ssh password on the command-line, we need
        # the sshpass tool to do that.  Production systems should use
        # ssh key files, of course, but sshpass is helpful for testing.
        check_tool_installed sshpass
    fi
    # You need to have the 'hdfs' script installed.
    check_tool_installed hdfs
}

ssh_to_node() {
    TGT=${1}
    shift
    if [ "x${SSH_USER}" != "x" ]; then
        TGT="${SSH_USER}@${TGT}"
    fi
    if [ "x${SSH_PASS}" == "x" ]; then
        ssh -o StrictHostKeyChecking=no "${TGT}" "${@}"
    else
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${TGT}" "${@}"
    fi
}

rsync_to_node() {
    SRC=${1}
    TGT=${2}
    shift
    shift
    RSYNC_ARGS="-avq --delete"
    if [ "x${SSH_USER}" != "x" ]; then
        TGT="${SSH_USER}@${TGT}"
    fi
    if [ "x${SSH_PASS}" == "x" ]; then
        rsync ${RSYNC_ARGS} "${SRC}" "${TGT}"
    else
        sshpass -p "${SSH_PASS}" rsync ${RSYNC_ARGS} -e ssh "${SRC}" "${TGT}"
    fi
}

check() {
    for datanode in ${DATANODES}; do
        ssh_to_node ${datanode} hostname
    done
}

format_dn() {
    for d in ${DATANODES}; do
        try_verbose ssh_to_node "${d}" "for s in ${STORAGE_DIRS}; do rm -rf \$s && mkdir -p \$s; done"
    done
}

load_fsgen_nn() {
    FSGEN_DIR="${1}"
    shift
    [[ "x${FSGEN_DIR}" == "x" ]] && die "load_fsgen_nn: you must specify the fsgen directory to use."
    FSIMAGE_XML="${FSGEN_DIR}/fsimage_0000000000000000001.xml"
    [ -f "${FSIMAGE_XML}" ] || \
        die "failed to find fsimage XML file at ${FSIMAGE_XML}"
    FSIMAGE_BIN="${FSGEN_DIR}/name/current/fsimage_0000000000000000001"
    try_verbose hdfs oiv -p ReverseXML -i "${FSIMAGE_XML}" -o "${FSIMAGE_BIN}"
    try_verbose rsync -avi --delete "${FSGEN_DIR}/name/" "/dfs/nn"
    try chown -R hdfs "/dfs/nn"
    echo "** Created new fsimage directory"
    find /dfs/nn/current -xdev -noleaf -type f -exec ls -lh {} \;
}

load_fsgen_dn() {
    FSGEN_DIR="${1}"
    TARGET_DATANODE=$(echo "${2}") # trim spaces
    shift
    shift
    [[ "x$FSGEN_DIR" == "x" ]] && die "load_fsgen_dn: you must specify the fsgen directory to use."
    [[ "x${TARGET_DATANODE}" == "x" ]] && die "You must supply a target datanode"
    DATANODE_IDX=1
    for DATANODE in ${DATANODES}; do
        if [[ "${DATANODE}" == "${TARGET_DATANODE}" ]]; then
            break;
        fi
        DATANODE_IDX=$((DATANODE_IDX+1))
        DATANODE=""
    done
    [[ "x${DATANODE}" == "x" ]] && die "no such datanode as '${TARGET_DATANODE}' configured in \$DATANODES"
    DIDX=$(printf %02d ${DATANODE_IDX})
    STORAGE_IDX=1
    for STORAGE_DIR in ${STORAGE_DIRS}; do
        SIDX=$(printf %02d ${STORAGE_IDX})
        rsync_to_node "${FSGEN_DIR}/datanode${DIDX}/storage${SIDX}/" "${DATANODE}:${STORAGE_DIR}"
        try_verbose ssh_to_node "${DATANODE}" chown -R hdfs "${STORAGE_DIR}"
        STORAGE_IDX=$((STORAGE_IDX+1))
    done
}

load_fsgen_dns() {
    FSGEN_DIR="${1}"
    shift
    [[ "x$FSGEN_DIR" == "x" ]] && die "load_fsgen_dn: you must specify the fsgen directory to use."
    DATANODE_IDX=1
    for DATANODE in ${DATANODES}; do
        load_fsgen_dn "${FSGEN_DIR}" "${DATANODE}"
    done
}

load_fsgen_dns_par() {
    FSGEN_DIR="${1}"
    shift
    echo ${DATANODES} |
      xargs -d ' ' --replace --max-procs=5 "${BASH_SOURCE}" load_fsgen_dn "${FSGEN_DIR}" "{}"
}

main() {
    # Print usage if required.
    ACTION="${1}"
    shift
    [[ "x${ACTION}" == "x" ]] && usage
    [[ "${ACTION}" == "-h" ]] && usage
    [[ "${ACTION}" == "--help" ]] && usage

    # Verify that things are set up properly.
    verify_environment

    case ${ACTION} in
        check) check;;
        format_dn) format_dn;;
        load_fsgen_nn) load_fsgen_nn "${@}";;
        load_fsgen_dn) load_fsgen_dn "${@}";;
        load_fsgen_dns) load_fsgen_dns "${@}";;
        load_fsgen_dns_par) load_fsgen_dns_par "${@}";;
        *) die "Can't understand action ${ACTION}... type -h for help."
    esac
}

main "${@}"
exit 0
