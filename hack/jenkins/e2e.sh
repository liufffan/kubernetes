#!/bin/bash

# Copyright 2015 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# kubernetes-e2e-{gce, gke, gke-ci} jobs: This script is triggered by
# the kubernetes-build job, or runs every half hour. We abort this job
# if it takes more than 75m. As of initial commit, it typically runs
# in about half an hour.
#
# The "Workspace Cleanup Plugin" is installed and in use for this job,
# so the ${WORKSPACE} directory (the current directory) is currently
# empty.

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

if [[ "${CIRCLECI:-}" == "true" ]]; then
    JOB_NAME="circleci-${CIRCLE_PROJECT_USERNAME}-${CIRCLE_PROJECT_REPONAME}"
    BUILD_NUMBER=${CIRCLE_BUILD_NUM}
    WORKSPACE=`pwd`
else
    # Jenkins?
    export HOME=${WORKSPACE} # Nothing should want Jenkins $HOME
fi

# Unlike the kubernetes-build script, we expect some environment
# variables to be set. We echo these immediately and presume "set -o
# nounset" will force the caller to set them: (The first several are
# Jenkins variables.)

echo "JOB_NAME: ${JOB_NAME}"
echo "BUILD_NUMBER: ${BUILD_NUMBER}"
echo "WORKSPACE: ${WORKSPACE}"
echo "KUBERNETES_PROVIDER: ${KUBERNETES_PROVIDER}" # Cloud provider
echo "E2E_CLUSTER_NAME: ${E2E_CLUSTER_NAME}"       # Name of the cluster (e.g. "e2e-test-jenkins")
echo "E2E_NETWORK: ${E2E_NETWORK}"                 # Name of the network (e.g. "e2e")
echo "E2E_ZONE: ${E2E_ZONE}"                       # Name of the GCE zone (e.g. "us-central1-f")
echo "E2E_OPT: ${E2E_OPT}"                         # hack/e2e.go options
echo "E2E_SET_CLUSTER_API_VERSION: ${E2E_SET_CLUSTER_API_VERSION:-<not set>}" # optional, for GKE, set CLUSTER_API_VERSION to git hash
echo "--------------------------------------------------------------------------------"


# AWS variables
export KUBE_AWS_INSTANCE_PREFIX=${E2E_CLUSTER_NAME}
export KUBE_AWS_ZONE=${E2E_ZONE}

# GCE variables
export INSTANCE_PREFIX=${E2E_CLUSTER_NAME}
export KUBE_GCE_ZONE=${E2E_ZONE}
export KUBE_GCE_NETWORK=${E2E_NETWORK}

# GKE variables
export CLUSTER_NAME=${E2E_CLUSTER_NAME}
export ZONE=${E2E_ZONE}
export KUBE_GKE_NETWORK=${E2E_NETWORK}

export PATH=${PATH}:/usr/local/go/bin
export KUBE_SKIP_CONFIRMATIONS=y

if [[ ${KUBE_RUN_FROM_OUTPUT:-} =~ ^[yY]$ ]]; then
    echo "Found KUBE_RUN_FROM_OUTPUT=y; will use binaries from _output"
    cp _output/release-tars/kubernetes*.tar.gz .
else
    echo "Pulling binaries from GCS"
    if [[ $(find . | wc -l) != 1 ]]; then
        echo $PWD not empty, bailing!
        exit 1
    fi

    sudo gcloud components update -q

    GITHASH=$(gsutil cat gs://kubernetes-release/ci/latest.txt)
    gsutil -m cp gs://kubernetes-release/ci/${GITHASH}/kubernetes.tar.gz gs://kubernetes-release/ci/${GITHASH}/kubernetes-test.tar.gz .
fi

md5sum kubernetes*.tar.gz
tar -xzf kubernetes.tar.gz
tar -xzf kubernetes-test.tar.gz
cd kubernetes

# Set by GKE-CI to change the CLUSTER_API_VERSION to the git version
if [[ ! -z ${E2E_SET_CLUSTER_API_VERSION:-} ]]; then
    export CLUSTER_API_VERSION=$(echo ${GITHASH} | cut -c 2-)
elif [[ ! -z ${E2E_USE_LATEST_RELEASE_VERSION:-} ]]; then
    release=$(gsutil cat gs://kubernetes-release/release/latest.txt | cut -c 2-)
    export CLUSTER_API_VERSION=${release}
fi

# Have cmd/e2e run by goe2e.sh generate JUnit report in ${WORKSPACE}/junit*.xml
export E2E_REPORT_DIR=${WORKSPACE}

### Set up ###
go run ./hack/e2e.go ${E2E_OPT} -v --down
go run ./hack/e2e.go ${E2E_OPT} -v --up
go run ./hack/e2e.go -v --ctl="version --match-server-version=false"

### Run tests ###
# Jenkins will look at the junit*.xml files for test failures, so don't exit
# with a nonzero error code if it was only tests that failed.
go run ./hack/e2e.go ${E2E_OPT} -v --test --test_args="--ginkgo.noColor" || true

### Clean up ###
go run ./hack/e2e.go ${E2E_OPT} -v --down
