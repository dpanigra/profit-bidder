# __author__ = [
#   'danikay@google.com (Danielle Kay)'
# ]

# Functions
function usage() {
  cat << EOF
install.sh
==========
Usage:
  install.sh [options]
Options:
  --project         GCP Project Id
  --dataset         The Big Query dataset to verify or create
Deployment directives:
  --activate-apis   Activate all missing but required Cloud APIs
  --create-service-account
                    Create the service account and client secrets
  --deploy-all Deploy all services
  --deploy-bigquery  Create BQ datasets
  --deploy-storage   Create storage buckets
  --deploy-delegator Create delegator cloud function
  --deploy-cm360-function Create cm360 cloud function

General switches:
  --dry-run         Don't do anything, just print the commands you would otherwise run. Useful
                    for testing.
EOF
}

function join { local IFS="$1"; shift; echo "$*"; }

# Switch definitions
PROJECT=
USER=
DATASET="profitbidder"

ACTIVATE_APIS=0
BACKGROUND=0
CREATE_SERVICE_ACCOUNT=0
USERNAME=0
ADMIN=

# Command line parser
while [[ $1 == -* ]] ; do
  case $1 in
    --project*)
      IFS="=" read _cmd PROJECT <<< "$1" && [ -z ${PROJECT} ] && shift && PROJECT=$1
      ;;
    --dataset*)
      IFS="=" read _cmd DATASET <<< "$1" && [ -z ${DATASET} ] && shift && DATASET=$1
      ;;
    --deploy-all)
      DEPLOY_BQ=1
      DEPLOY_STORAGE=1
      DEPLOY_DELEGATOR=1
      DEPLOY_CM360_FUNCTION=1
      ACTIVATE_APIS=1
      CREATE_SERVICE_ACCOUNT=1
      ;;
    --deploy-bigquery)
      DEPLOY_BQ=1
      ;;
    --deploy-storage)
      DEPLOY_STORAGE=1
      ;;
    --deploy-delegator)
      DEPLOY_DELEGATOR=1
      ;;
    --deploy-cm360-function)
      DEPLOY_CM360_FUNCTION=1
      ;;
    --activate-apis)
      ACTIVATE_APIS=1
      ;;
    --create-service-account)
      CREATE_SERVICE_ACCOUNT=1
      ;;
    --dry-run)
      DRY_RUN=echo
      ;;
    --no-code)
      DEPLOY_CODE=0
      ;;
    *)
      usage
      echo -e "\nUnknown parameter $1."
      exit
  esac
  shift
done


if [ -z "${PROJECT}" ]; then
  usage
  echo -e "\nYou must specify a project to proceed."
  exit
fi

USER=profit-bidder@${PROJECT}.iam.gserviceaccount.com
if [ ! -z ${ADMIN} ]; then
  _ADMIN="ADMINISTRATOR_EMAIL=${ADMIN}"
fi

if [ ${ACTIVATE_APIS} -eq 1 ]; then
  # Check for active APIs
  APIS_USED=(
    "bigquery"
    "bigquerystorage"
    "bigquerydatatransfer"
    "cloudfunctions"
    "doubleclickbidmanager"
    "doubleclicksearch"
    "pubsub"
    "storage-api"
  )
  ACTIVE_SERVICES="$(gcloud --project=${PROJECT} services list | cut -f 1 -d' ' | grep -v NAME)"

  for api in ${APIS_USED[@]}; do
    if [[ "${ACTIVE_SERVICES}" =~ ${api} ]]; then
      echo "${api} already active"
    else
      echo "Activating ${api}"
      ${DRY_RUN} gcloud --project=${PROJECT} services enable ${api}.googleapis.com
    fi
  done
fi

# create service account
if [ ${CREATE_SERVICE_ACCOUNT} -eq 1 ]; then
  ${DRY_RUN} gcloud iam service-accounts create profit-bidder --description "Profit Bidder Service Account" --project ${PROJECT}
fi


# create cloud storage bucket
if [ ${DEPLOY_STORAGE} -eq 1 ]; then
  # Create buckets
  for bucket in conversion-upload_log; do
    gsutil ls -p ${PROJECT} gs://${PROJECT}-${bucket} > /dev/null 2>&1
    RETVAL=$?
    if (( ${RETVAL} != "0" )); then
      ${DRY_RUN} gsutil mb -p ${PROJECT} gs://${PROJECT}-${bucket}
    fi
  done
fi

# create bq datasets
if [ ${DEPLOY_BQ} -eq 1 ]; then
  # Create dataset
  for dataset in sa360_data gmc_data business_data; do
    bq --project_id=${PROJECT} show --dataset ${DATASET} > /dev/null 2>&1
    RETVAL=$?
    if (( $RETVAL != "0" )); then
      ${DRY_RUN} bq --project_id=${PROJECT} mk --dataset ${DATASET}
    fi
  done
fi

echo ${DEPLOY_DELEGATOR}
# create cloud funtions
if [ ${DEPLOY_DELEGATOR} -eq 1 ]; then
 # Create scheduled job
  ${DRY_RUN} gcloud beta scheduler jobs delete \
    --project=${PROJECT} \
    --quiet \
    "delegator-scheduler"

  ${DRY_RUN} gcloud beta scheduler jobs create pubsub \
    "delegator" \
    --schedule="0 6 * * *" \
    --topic="conversion_upload_delegator" \
    --message-body="RUN" \
    --project=${PROJECT}

  echo "Deploying Delegator Cloud Function"
  ${DRY_RUN} gcloud functions deploy "cloud_conversion_upload_delegator" \
    --region=us-central1 \
    --trigger-topic=conversion_upload_delegator \
    --memory=2GB \
    --timeout=540s \
    --runtime python37 \
    --entry-point=main \
fi

if [ ${DEPLOY_CM360_FUNCTION} -eq 1 ]; then
 # Create scheduled job
  ${DRY_RUN} gcloud beta scheduler jobs delete \
    --project=${PROJECT} \
    --quiet \
    "cm360-scheduler"

  ${DRY_RUN} gcloud beta scheduler jobs create pubsub \
    "cm360-scheduler"
    --schedule="0 6 * * *" \
    --topic="conversion_upload_delegator" \
    --message-body="RUN" \
    --project=${PROJECT}

 echo "Deploying CM360 Cloud Function"
  ${DRY_RUN} gcloud functions deploy "cm360_cloud_conversion_upload_node" \
    --region=us-central1 \
    --trigger-topic=cm360_conversion_upload \
    --memory=256MB \
    --timeout=540s \
    --runtime python37 \
    --entry-point=main \
fi
