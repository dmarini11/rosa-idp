#!/bin/bash

export ORIGIN_URL=`git config --get remote.origin.url`
if [ -z "$ORIGIN_URL" ]; then
  echo "Move into the github project root to launch this script."
  exit;
fi
echo "Current repo url is: $ORIGIN_URL"
if [[ "$ORIGIN_URL" == *"dopen-sudo"* ]]; then
  echo "You CANNOT apply these changes to open-sudo"
  exit;
fi
 
export GITHUB_BASE_URL=`dirname $ORIGIN_URL`
export GITHUB_NAME=`basename $GITHUB_BASE_URL`
export GITHUB_NAME="${GITHUB_BASE_URL##*github.com?}"
echo "GitHub name is: $GITHUB_NAME"

if [ -z $GITHUB_NAME ]
then
    echo "Could not extract github user name"
    exit;
fi
status_code=$(curl --write-out '%{http_code}' --silent --output /dev/null https://github.com/$1)

if [[ "$status_code" -ne 200 ]] ; then
  echo "https://github.com/$1 returns status code: $status_code. I was expecting 200"
  exit 0
fi

echo "https://github.com/${GITHUB_NAME} successfully validated"

export OCP_TOKEN=`oc whoami --show-token`

if [ -z "$OCP_TOKEN" ]
then
    echo "No OpenShift token found. You might not be logged in."
    exit;
fi

echo "OCP Token found"

export CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}"  |  rev | cut -c7- | rev)

if [ -z "$CLUSTER_NAME" ]
then
      echo "Cluster name could not be determined. You might not be logged in."
      exit;
fi
echo "Cluster name found: $CLUSTER_NAME"

export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
if [ -z "$REGION" ]
then
      echo "Region could not be determined. You might not be logged in."
      exit;
fi

echo "Region found: $REGION"
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer | sed  's|^https://||')
if [ -z "$OIDC_ENDPOINT" ]
then
      echo "OIDC Endpoint could not be determined. You might not be logged in."
      exit;
fi
echo "OIDC_ENDPOINT Found: $OIDC_ENDPOINT"
export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
if [ -z "$AWS_ACCOUNT_ID" ]
then
      echo "AWS Account ID could not be determined. You might not be logged in."
      exit;
fi

echo "AWS Account ID found: $AWS_ACCOUNT_ID"

export current=`git config --get remote.origin.url`
echo "Current repo url is: $current"
if [[ "$current" == *"open-sudo"* ]]; then
  echo "You CANNOT apply these changes to open-sudo"
fi

ROOT_APP="argocd/root-application.yaml"


export GSED=`which gsed`
if [ ! -z "$GSED" ]; then
   COMMAND="gsed"
else
   COMMAND="sed"
fi


echo "Using : $COMMAND"
find . -type f -not -path '*/\.git/*' -not -name '*.sh'  -exec $COMMAND -i "s|open-sudo|${GITHUB_NAME}|g" {} +
$COMMAND -i "s|awsAccountId:.*|awsAccountId: \'${AWS_ACCOUNT_ID}\'|" $ROOT_APP
$COMMAND -i "s|clusterName:.*|clusterName: ${CLUSTER_NAME}|" $ROOT_APP
$COMMAND -i "s|awsRegion:.*|awsRegion: ${REGION}|" $ROOT_APP


aws cloudformation create-stack --template-body file://cloudformation/rosa-cloudwatch-logging-role.yaml \
       --capabilities CAPABILITY_NAMED_IAM --parameters ParameterKey=OidcProvider,ParameterValue=$OIDC_ENDPOINT \
         ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME} --stack-name rosa-idp-cw-logs-${CLUSTER_NAME}

aws cloudformation create-stack --template-body file://cloudformation/rosa-cloudwatch-metrics-credentials.yaml \
     --capabilities CAPABILITY_NAMED_IAM --parameters  ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME}  --stack-name rosa-idp-cw-metrics-credentials-${CLUSTER_NAME}

aws cloudformation create-stack --template-body file://cloudformation/rosa-ecr.yaml \
     --capabilities CAPABILITY_IAM  --parameters  ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME}  --stack-name rosa-idp-ecr-${CLUSTER_NAME}

aws cloudformation create-stack --template-body file://cloudformation/rosa-iam-external-secrets-rds-role.yaml \
    --capabilities CAPABILITY_NAMED_IAM --parameters ParameterKey=OidcProvider,ParameterValue=$OIDC_ENDPOINT \
      ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME} --stack-name rosa-idp-iam-external-secrets-rds-${CLUSTER_NAME}

aws cloudformation create-stack --template-body file://cloudformation/rosa-iam-external-secrets-role.yaml \
    --capabilities CAPABILITY_NAMED_IAM --parameters ParameterKey=OidcProvider,ParameterValue=$OIDC_ENDPOINT \
      ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME} --stack-name rosa-idp-iam-external-secrets-${CLUSTER_NAME}


aws cloudformation create-stack --template-body file://cloudformation/rosa-rds-inventory-credentials.yaml \
     --capabilities CAPABILITY_NAMED_IAM  --parameters  ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME} --stack-name rosa-idp-rds-inventory-credentials-${CLUSTER_NAME}


  
STACK_NAMES=("rosa-idp-cw-logs-${CLUSTER_NAME}" "rosa-idp-rds-inventory-credentials-${CLUSTER_NAME}"  "rosa-idp-iam-external-secrets-${CLUSTER_NAME}" 
"rosa-idp-iam-external-secrets-rds-${CLUSTER_NAME}"  "rosa-idp-cw-metrics-credentials-${CLUSTER_NAME}")

echo "===========================CloudFormation Status==========================="


for stack in ${!STACK_NAMES[@]}
do
        STACK_NAME="${STACK_NAMES[stack]}"
        StackResultStatus="CREATE_IN_PROGRESS"

        while [ $StackResultStatus == "CREATE_IN_PROGRESS" ]
        do
                sleep 5
                StackResult=`aws cloudformation describe-stacks --stack-name ${STACK_NAME}`
                StackResultStatus=`echo $StackResult  | jq -r '.Stacks[0].StackStatus'`
                echo "${STACK_NAME} : $StackResultStatus"
        done
        echo -e "\n"
        if [[ "$StackResultStatus" != *"CREATE_COMPLETE"* ]]; then
                echo -e "Problems executing stack: $STACK_NAME. Find out more with:\n\n      aws cloudformation describe-stack-events --stack-name $STACK_NAME \n\n";
                exit;
        fi
done






echo -e "Commiting changes to $ORIGIN_URL\n"
git add -A
git commit -m "Initial commit"

echo -e "\n\nPlease execute following command next:       git push\n\n"


     

