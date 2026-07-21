pipeline {
    agent any

    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'destroy'],
               description: 'Deploy the goat or tear it down')
        booleanParam(name: 'RUN_SECURITY_SCAN', defaultValue: true,
               description: 'Run Trivy after deploy (findings are EXPECTED — informational only)')
    }

    environment {
        AWS_REGION       = 'us-east-2'
        EKS_CLUSTER_NAME = 'juice-shop-cluster'
        EXPECTED_CONTEXT = 'goat-lab'
        GOAT_NAMESPACE   = 'default'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Auth to EKS') {
            steps {
                sh '''#!/bin/bash

                    set -euo pipefail
                    aws sts get-caller-identity
                    aws eks update-kubeconfig \
                        --name "${EKS_CLUSTER_NAME}" \
                        --region "${AWS_REGION}" \
                        --alias "${EXPECTED_CONTEXT}"
                '''
            }
        }

        stage('Preflight') {
            steps {
                sh '''#!/bin/bash

                    set -euo pipefail
                    echo "== tool versions =="
                    kubectl version --client=true
                    helm version

                    CTX=$(kubectl config current-context)
                    echo "current context: ${CTX}"
                    if [ "${CTX}" != "${EXPECTED_CONTEXT}" ]; then
                      echo "REFUSING TO RUN: context '${CTX}' != expected '${EXPECTED_CONTEXT}'."
                      exit 1
                    fi
                    case "${EKS_CLUSTER_NAME}" in
                      *prod*) echo "REFUSING TO RUN: cluster name contains 'prod'."; exit 1 ;;
                    esac
                    kubectl cluster-info
                    kubectl auth can-i get pods
                '''
            }
        }

        stage('Deploy') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh '''#!/bin/bash

                    set -euo pipefail
                    chmod +x setup-kubernetes-goat.sh
                    bash setup-kubernetes-goat.sh
                '''
            }
        }

        stage('Verify') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh '''#!/bin/bash

                    set -euo pipefail
                    echo "== pods in ${GOAT_NAMESPACE} =="
                    kubectl -n "${GOAT_NAMESPACE}" get pods
                    kubectl -n "${GOAT_NAMESPACE}" wait --for=condition=Ready pods --all --timeout=240s \
                      || kubectl -n "${GOAT_NAMESPACE}" get pods
                '''
            }
        }

        stage('Security Scan') {
            when {
                allOf {
                    expression { params.ACTION == 'deploy' }
                    expression { params.RUN_SECURITY_SCAN }
                }
            }
            steps {
                sh '''#!/bin/bash

                    set +e
                    if command -v trivy >/dev/null 2>&1; then
                      trivy k8s --namespace "${GOAT_NAMESPACE}" --report summary --scanners misconfig \
                        > trivy-report.txt 2>&1 || true
                    else
                      echo "trivy not installed on this agent; skipping scan" > trivy-report.txt
                    fi
                    cat trivy-report.txt
                '''
                archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
            }
        }

        stage('Destroy') {
            when { expression { params.ACTION == 'destroy' } }
            steps {
                sh '''#!/bin/bash

                    set +e
                    chmod +x teardown-kubernetes-goat.sh
                    bash teardown-kubernetes-goat.sh
                '''
            }
        }
    }

    post {
        success { echo "Pipeline action '${params.ACTION}' completed." }
        failure { echo "Pipeline failed — check Auth to EKS / Preflight output above." }
        always  { cleanWs() }
    }
}
