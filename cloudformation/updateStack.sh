#!/bin/bash
STACK_UPDATE_TIMEOUT=400
CAPABILITIES=CAPABILITY_IAM

usage() {
  echo "Usage: updateStack.sh <access_key_id> <secret_access_key> <stack_name>"
  exit 1
}
BAMBOO_WORKING_DIR=$4
source $BAMBOO_WORKING_DIR/common.func

# Essential Variables
export AWS_ACCESS_KEY_ID=$1
export AWS_SECRET_ACCESS_KEY=$2

IFS='-' read -a myarray <<< "$3"
BRANCH='test'
if [ "${myarray[1]}" == "master" ]; then
  BRANCH='prod'
fi
NUMBER="${myarray[2]}"
STACK_NAME="online-trial-control-$BRANCH"
logInfo "Updating $STACK_NAME"

# Replace placeholders
CURRENT_TIME=$(date +%s)
separator
logInfo "Replacing placeholders in parameters-update.json"
sed -i'.bak' "
    s/@@UPDATED_TIME@@/$CURRENT_TIME/g
" parameters-update.json

# We need to create a change set for the current stack, describe the change set and check the response for the "STATUS"
# if the status was "FAILED" this was because there we no changes to execute, so we delete the change set then exit early
# otherwise we execute the change set
S3_TEMPLATE_NAME="$3.yaml"
CHANGE_SET_NAME="$BRANCH-update-$NUMBER"
aws cloudformation create-change-set --stack-name $STACK_NAME --template-url https://s3.amazonaws.com/$S3_BUCKET/$S3_TEMPLATE_NAME --parameters file://parameters-update.json --change-set-name $CHANGE_SET_NAME --capabilities $CAPABILITIES

# give the changeset time to be created
separator
logInfo "Waiting for the change set to be created...."
STATUS=$(aws cloudformation describe-change-set --stack-name $STACK_NAME --change-set-name $CHANGE_SET_NAME --query "Status" --output text)
while [ "$STATUS" == "CREATE_IN_PROGRESS" ]
do
  sleep 30
  logInfo "Waiting for the change set to be created...."
  STATUS=$(aws cloudformation describe-change-set --stack-name $STACK_NAME --change-set-name $CHANGE_SET_NAME --query "Status" --output text)
done

if [ "$STATUS" == "FAILED" ]; then
  separator
  logInfo "No updates to execute on $STACK_NAME. Exiting"
  aws cloudformation delete-change-set --stack-name $STACK_NAME --change-set-name $CHANGE_SET_NAME
  exit 0
fi

separator
logInfo "Updating stack $STACK_NAME"
aws cloudformation execute-change-set --change-set-name $CHANGE_SET_NAME --stack-name $STACK_NAME
if [ $? -ne 0 ]; then
  logError "Stack update failed."
fi

separator
logInfo "Waiting for stack update $STACK_NAME"
UPDATE_COMPLETE_EVENT="FALSE"
LOOP_COUNTER=0
while [ "$UPDATE_COMPLETE_EVENT" != "UPDATE_COMPLETE" ]
do
    if [ $LOOP_COUNTER -eq $STACK_UPDATE_TIMEOUT ]; then
        TIMEOUT_IN_MIN=`expr $STACK_UPDATE_TIMEOUT / 6`
        logError "Stack update timeout after $TIMEOUT_IN_MIN minutes"
    fi

    STATUS=`aws cloudformation describe-stack-events --stack-name $STACK_NAME | head -n 10 | grep -B1 AWS::CloudFormation::Stack`
    monitorStatus "$STATUS"
    sleep 10
    LOOP_COUNTER=`expr $LOOP_COUNTER + 1`
done