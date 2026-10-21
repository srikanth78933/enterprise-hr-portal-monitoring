// Monitoring pipeline for one environment (dev or prod):
//   1. ELK stack on its EC2 instance: upload elk/ to S3, run scripts/deploy.sh through AWS Systems Manager
//   2. Filebeat + Metricbeat DaemonSets on the environment's EKS cluster (Helm)
pipeline {
    agent any

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'prod'], description: 'Environment to monitor')
    }

    environment {
        AWS_REGION    = 'ap-south-1'
        EKS_CLUSTER   = "mycompany-${params.ENVIRONMENT}-eks"
        K8S_NAMESPACE = 'monitoring'

        // Names created by the infra repo (enable_elk = true)
        ELK_NAME      = "enterprise-hr-portal-${params.ENVIRONMENT}-elk"   // EC2 Name tag; config bucket is <ELK_NAME>-config-<account-id>
        ELK_SECRET_ID = "enterprise-hr-portal/${params.ENVIRONMENT}/elk"
        KIBANA_ALB    = "hrp-${params.ENVIRONMENT}-kibana"

        AWS_ACCESS_KEY_ID     = credentials('AWS_ACCESS_KEY_ID')
        AWS_SECRET_ACCESS_KEY = credentials('AWS_SECRET_ACCESS_KEY')
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
        timeout(time: 45, unit: 'MINUTES')
    }

    stages {
        stage('Validate') {
            steps {
                sh '''
                    bash -n elk/scripts/deploy.sh
                    bash -n elk/scripts/setup.sh
                    helm lint helm/beats -f environments/$ENVIRONMENT/values.yaml --set elk.host=127.0.0.1
                '''
            }
        }

        stage('Find ELK Instance') {
            steps {
                script {
                    def info = sh(returnStdout: true, script: '''
                        aws ec2 describe-instances --region $AWS_REGION \
                            --filters "Name=tag:Name,Values=$ELK_NAME" "Name=instance-state-name,Values=running" \
                            --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]' --output text
                    ''').trim().split()
                    if (info.size() != 2 || info[0] == 'None') {
                        error("No running EC2 instance tagged Name=${env.ELK_NAME}. Run terraform apply for ${params.ENVIRONMENT} (enable_elk = true) in the infra repo first.")
                    }
                    env.ELK_INSTANCE_ID = info[0]
                    env.ELK_PRIVATE_IP  = info[1]
                    env.ELK_CONFIG_BUCKET = sh(returnStdout: true,
                        script: 'echo "${ELK_NAME}-config-$(aws sts get-caller-identity --query Account --output text)"').trim()
                }
                echo "ELK instance ${env.ELK_INSTANCE_ID} (${env.ELK_PRIVATE_IP}), config bucket ${env.ELK_CONFIG_BUCKET}"
            }
        }

        stage('Approve Production') {
            when {
                expression { params.ENVIRONMENT == 'prod' }
            }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: 'Deploy the ELK stack and Beats to PRODUCTION?', ok: 'Deploy'
                }
            }
        }

        stage('Upload ELK Config') {
            steps {
                sh 'aws s3 sync elk/ "s3://$ELK_CONFIG_BUCKET/elk/" --delete --exclude ".env" --region $AWS_REGION'
            }
        }

        stage('Deploy ELK on EC2') {
            steps {
                sh '''
                    # Commands run as root on the instance by Systems Manager (no SSH needed)
                    cat > ssm-params.json <<EOF
{
  "commands": [
    "set -e",
    "export PATH=\\$PATH:/snap/bin",
    "mkdir -p /opt/elk",
    "aws s3 sync s3://${ELK_CONFIG_BUCKET}/elk/ /opt/elk/ --delete --exclude .env --region ${AWS_REGION}",
    "chmod +x /opt/elk/scripts/*.sh",
    "ELK_ENVIRONMENT=${ENVIRONMENT} ELK_SECRET_ID=${ELK_SECRET_ID} AWS_REGION=${AWS_REGION} /opt/elk/scripts/deploy.sh"
  ],
  "executionTimeout": ["1800"]
}
EOF
                    CMD_ID=$(aws ssm send-command --region $AWS_REGION \
                        --instance-ids $ELK_INSTANCE_ID \
                        --document-name AWS-RunShellScript \
                        --comment "Deploy ELK (Jenkins build $BUILD_NUMBER)" \
                        --parameters file://ssm-params.json \
                        --query Command.CommandId --output text)
                    echo "SSM command: $CMD_ID"

                    STATUS=Pending
                    for i in $(seq 1 180); do
                        STATUS=$(aws ssm get-command-invocation --region $AWS_REGION --command-id $CMD_ID \
                            --instance-id $ELK_INSTANCE_ID --query Status --output text 2>/dev/null || echo Pending)
                        case "$STATUS" in
                            Pending|InProgress|Delayed) sleep 10 ;;
                            *) break ;;
                        esac
                    done

                    echo "----- output from the ELK instance -----"
                    aws ssm get-command-invocation --region $AWS_REGION --command-id $CMD_ID \
                        --instance-id $ELK_INSTANCE_ID --query StandardOutputContent --output text
                    aws ssm get-command-invocation --region $AWS_REGION --command-id $CMD_ID \
                        --instance-id $ELK_INSTANCE_ID --query StandardErrorContent --output text

                    [ "$STATUS" = "Success" ] || { echo "ELK deploy finished with status: $STATUS"; exit 1; }
                '''
            }
        }

        stage('Beats Credentials') {
            steps {
                sh '''
                    # Don't print the password in the build log
                    set +x
                    aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER
                    kubectl create namespace $K8S_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
                    METRICBEAT_PASSWORD=$(aws secretsmanager get-secret-value --region $AWS_REGION \
                        --secret-id $ELK_SECRET_ID --query SecretString --output text | jq -r .metricbeat_writer_password)
                    kubectl create secret generic elk-credentials -n $K8S_NAMESPACE \
                        --from-literal=METRICBEAT_PASSWORD="$METRICBEAT_PASSWORD" \
                        --dry-run=client -o yaml | kubectl apply -f -
                    echo "Secret elk-credentials updated"
                '''
            }
        }

        stage('Deploy Beats to EKS') {
            steps {
                sh '''
                    helm upgrade --install beats helm/beats \
                        --namespace $K8S_NAMESPACE \
                        -f environments/$ENVIRONMENT/values.yaml \
                        --set elk.host=$ELK_PRIVATE_IP \
                        --wait --timeout 5m
                    kubectl get daemonset,pods -n $K8S_NAMESPACE -o wide
                '''
            }
        }
    }

    post {
        always {
            sh 'rm -f ssm-params.json'
        }
        success {
            script {
                def kibana = sh(returnStdout: true, script: '''
                    aws elbv2 describe-load-balancers --region $AWS_REGION --names $KIBANA_ALB \
                        --query 'LoadBalancers[0].DNSName' --output text
                ''').trim()
                echo "Monitoring deployed. Kibana: http://${kibana} (user: elastic, password in Secrets Manager ${env.ELK_SECRET_ID})"
            }
        }
        failure {
            echo 'Monitoring pipeline failed. Check the stage logs above.'
        }
    }
}
