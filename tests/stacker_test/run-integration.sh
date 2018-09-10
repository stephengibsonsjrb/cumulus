#!/usr/bin/env bash

ACCOUNT_ID=`aws sts get-caller-identity | jq .Account | tr -d '"' `
NAMESPACE=acc # must match the namespace in the conf file
BUCKET="cumulus-${NAMESPACE}-${ACCOUNT_ID}-automatedtests"

echo "Using account: ${ACCOUNT_ID}"
echo "Using bucket: ${BUCKET}"

set -e #Important. Script will exit appropriately if there is an error.

stacker build conf/acceptance.env stacker.yaml --recreate-failed -t

ARTIFACT_NAME='artifact.tar.gz'
TEMP_DIR='ac_build'

pushd ../../ # move to main folder
mkdir -p ${TEMP_DIR}
zip -r ${TEMP_DIR}/${ARTIFACT_NAME} ./ -x *.git* *./${TEMP_DIR}* *.eggs* *.idea* *.tox*

aws s3 cp ./${TEMP_DIR}/${ARTIFACT_NAME} s3://${BUCKET}/${ARTIFACT_NAME}

rm -rf ${TEMP_DIR}
popd # return to test folder

PIPELINE_NAME=$(stacker info conf/acceptance.env stacker.yaml 2>&1 | grep PipelineLogicalName | cut -f 3 -d " ")

echo "Pipeline deployment started for pipeline: ${PIPELINE_NAME}"

# get shasum from expected and actual output. When they match we are at approval state
expected_pipeline_state=$(echo -e "SourceStage Succeeded\nDeployStage Succeeded\nEchoAURL InProgress" | shasum)

set +e # turn off error mode, ie don't exit with a failure, let the loop continue
end=$((SECONDS+600))
pipeline_result=1
while [ $SECONDS -lt ${end} ]; do
    sleep 15
    # Get status from each stage in the pipeline
    pipeline_state=$(aws codepipeline get-pipeline-state --name ${PIPELINE_NAME} | jq -r '.stageStates[] | "\(.stageName) \(.latestExecution.status)"')
    actual_pipeline_state=$(aws codepipeline get-pipeline-state --name ${PIPELINE_NAME} | jq -r '.stageStates[] | "\(.stageName) \(.latestExecution.status)"' | shasum)
    echo ${pipeline_state}
    echo Expected: ${expected_pipeline_state}
    echo Actual:   ${actual_pipeline_state}
    # First check that the resulting shasum is identical to our expected state.
    if [[ ${expected_pipeline_state} == ${actual_pipeline_state} ]] ; then
        echo "Pipeline Succeeded to approval step!"
        pipeline_result=0 #the only place this is set to true
        break;
    # If it isn't, fail if the pipeline failed.  Otherwise continue and check again
    else
        if [[ ${pipeline_state} = *"Failed"* ]]; then
            echo "Pipeline Failed."
            break;
        else
            printf "."
        fi
    fi
done


SHOULD_DESTROY=false
if $SHOULD_DESTROY; then
    aws s3 rm s3://${BUCKET} --recursive
    python delete_bucket_versions.py ${BUCKET}

    stacker destroy conf/acceptance.env stacker.yaml --force -t
fi

echo "Completing with exit code ${pipeline_result}"

exit ${pipeline_result} #
