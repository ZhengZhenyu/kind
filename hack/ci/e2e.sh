#!/usr/bin/env bash
# Copyright 2018 The Kubernetes Authors.
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

# hack script for running a kind e2e
# must be run with a kubernetes checkout in $PWD (IE from the checkout)
# Usage: SKIP="ginkgo skip regex" FOCUS="ginkgo focus regex" kind-e2e.sh

set -o errexit -o nounset -o pipefail -o xtrace

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# our exit handler (trap)
cleanup() {
  # always attempt to dump logs
  kind "export" logs "${ARTIFACTS}/logs" || true
  # KIND_IS_UP is true once we: kind create
  if [[ "${KIND_IS_UP:-}" = true ]]; then
    kind delete cluster || true
  fi
  # clean up e2e.test symlink
  rm -f _output/bin/e2e.test || true
  # remove our tempdir
  # NOTE: this needs to be last, or it will prevent kind delete
  if [[ -n "${TMP_DIR:-}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

# install kind to a tempdir GOPATH from this script's kind checkout
install_kind() {
  mkdir -p "${TMP_DIR}/bin"
  make -C "${REPO_ROOT}" install INSTALL_PATH="${TMP_DIR}/bin"
  export PATH="${TMP_DIR}/bin:${PATH}"
}

# build kubernetes / node image, e2e binaries
build() {
  # possibly enable bazel build caching before building kubernetes
  if [[ "${BAZEL_REMOTE_CACHE_ENABLED:-false}" == "true" ]]; then
    create_bazel_cache_rcs.sh || true
  fi

  # build the node image w/ kubernetes
  kind build node-image --type=bazel --kube-root="$(go env GOPATH)/src/k8s.io/kubernetes"

  # make sure we have e2e requirements
  #make all WHAT="cmd/kubectl test/e2e/e2e.test vendor/github.com/onsi/ginkgo/ginkgo"
  bazel build //cmd/kubectl //test/e2e:e2e.test //vendor/github.com/onsi/ginkgo/ginkgo

  # ensure the e2e script will find our binaries ...
  # https://github.com/kubernetes/kubernetes/issues/68306
  mkdir -p '_output/bin/'
  cp "bazel-bin/test/e2e/e2e.test" "_output/bin/"
  PATH="$(dirname "$(find "${PWD}/bazel-bin/" -name kubectl -type f)"):${PATH}"
  export PATH

  # attempt to release some memory after building
  sync || true
  echo 1 > /proc/sys/vm/drop_caches || true
}

# up a cluster with kind
create_cluster() {
  # create the config file
  cat <<EOF > "${ARTIFACTS}/kind-config.yaml"
# config for 1 control plane node and 2 workers
# necessary for conformance
kind: Cluster
apiVersion: kind.sigs.k8s.io/v1alpha3
networking:
  ipFamily: ${IP_FAMILY:-ipv4}
nodes:
# the control plane node
- role: control-plane
- role: worker
- role: worker
EOF

  # actually create the cluster
  KIND_IS_UP=true
  kind create cluster \
    --image=kindest/node:latest \
    --retain \
    --wait=1m \
    --loglevel=debug \
    "--config=${ARTIFACTS}/kind-config.yaml"
}

# run e2es with kubetest
run_tests() {
  # export the KUBECONFIG
  KUBECONFIG="$(kind get kubeconfig-path)"
  export KUBECONFIG

  # IPv6 clusters need some CoreDNS changes in order to work in k8s CI:
  # 1. k8s CI doesn´t offer IPv6 connectivity, so CoreDNS should be configured
  # to work in an offline environment:
  # https://github.com/coredns/coredns/issues/2494#issuecomment-457215452
  # 2. k8s CI adds following domains to resolv.conf search field:
  # c.k8s-prow-builds.internal google.internal.
  # CoreDNS should handle those domains and answer with NXDOMAIN instead of SERVFAIL
  # otherwise pods stops trying to resolve the domain.
  if [[ "${IP_FAMILY:-ipv4}" == "ipv6" ]]; then
    # Get the current config
    local original_coredns
    original_coredns=$(kubectl get -oyaml -n=kube-system configmap/coredns)
    echo "Original CoreDNS config:"
    echo "${original_coredns}"
    # Patch it
    local fixed_coredns
    fixed_coredns=$(
      sed \
        -e 's/^.*kubernetes cluster\.local/& internal/' \
        -e '/^.*upstream$/d' \
        -e '/^.*fallthrough.*$/d' \
        -e '/^.*forward . \/etc\/resolv.conf$/d' \
        -e '/^.*loop$/d' \
      <<< "${original_coredns}"
    )
    echo "Patched CoreDNS config:"
    echo "${fixed_coredns}"
    kubectl apply -f - <<< "${fixed_coredns}"
    # restart the pods
    kubectl -n kube-system delete pods -l k8s-app=kube-dns
  fi

  # ginkgo regexes
  SKIP="${SKIP:-}"
  FOCUS="${FOCUS:-"\\[Conformance\\]"}"
  # if we set PARALLEL=true, skip serial tests set --ginkgo-parallel
  if [[ "${PARALLEL:-false}" == "true" ]]; then
    export GINKGO_PARALLEL=y
    if [[ -z "${SKIP}" ]]; then
      SKIP="\\[Serial\\]"
    else
      SKIP="\\[Serial\\]|${SKIP}"
    fi
  fi

  # get the number of worker nodes
  # TODO(bentheelder): this is kinda gross
  NUM_NODES="$(kubectl get nodes \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}' \
    | grep -cv "node-role.kubernetes.io/master" )"

  # setting this env prevents ginkg e2e from trying to run provider setup
  export KUBERNETES_CONFORMANCE_TEST="y"
  # run the tests
  ./hack/ginkgo-e2e.sh \
    '--provider=skeleton' "--num-nodes=${NUM_NODES}" \
    "--ginkgo.focus=${FOCUS}" "--ginkgo.skip=${SKIP}" \
    "--report-dir=${ARTIFACTS}" '--disable-log-dump=true'
}

# setup kind, build kubernetes, create a cluster, run the e2es
main() {
  # create temp dir and setup cleanup
  TMP_DIR=$(mktemp -d)
  trap cleanup EXIT
  # ensure artifacts exists when not in CI
  ARTIFACTS="${ARTIFACTS:-${PWD}/_artifacts}"
  export ARTIFACTS
  mkdir -p "${ARTIFACTS}"
  # now build and run the cluster and tests
  install_kind
  build
  create_cluster
  run_tests
}

main
