#!/bin/bash
# MAINTAINER: Jose Antonio Gonzalez Prada <josgonza@redhat.com>
#
# Based in: https://docs.openshift.com/container-platform/4.5/operators/admin/olm-restricted-networks.html
#

# echo an error message before exiting
trap 'if [ "$last_command" != "exit 0" ]; then log "${RED}" "\"${last_command}\" command filed with exit code $?."; fi' EXIT

#set -eo pipefail
#set -ex
set -e

FILEPATH="$(readlink -f $0)"
BASEDIR="${FILEPATH%/*}"

#####################
##### FUNCTIONS #####

# Function that shows the command's common usage
usage(){
    echo
    echo "# Usage: $0 [--help|-h] [rh|co]"
    echo "#"
    echo "# - example: $0 rh"
    echo "# - creates:: Custom Catalog from the redhat-operators Catalog" 
    echo
    echo "# - example: $0 co"
    echo "# - creates:: Custom Catalog from the community-operators Catalog" 
    echo    
}

# Generate the CatalogSource yaml file
create_template(){
  local template_name="${1}"

  sed -e "s#NAME#${CONFIG[NAME]}#g" \
    -e "s#PROJECT#${CONFIG[PROJECT]}#g" \
    -e "s#DISPLAY#${CONFIG[DISPLAY]}#g" \
    -e "s#IMAGE#${CONFIG[IMAGE]}#g" \
    ${CS_TEMPLATE} > "${template_name}"

  log "${YELLOW}" "Created template **${template_name}**"

}

# log the $2 message to ${LOG_FILE} with LEVEL $1
function log() {
  local color="${1}"
  local msg="${2}"
  local now=$(date +"%d/%m/%Y - %H:%M:%S")

  echo
  echo -e "${now} ${color} | ${msg}${NC}"
  echo

}

################
##### MAIN #####

main(){

  local -a OPERATORS=()
  local cmd_type=""
  local cs_template_file=""
  local manifest_path=""
  #Storing current environment settings
  local oldopt=$-

  ## Global args in Uppercase
  CFG_FILE="${BASEDIR}/config/catalog.cfg"

  ## Read Configuration file
  if [[ -r "${CFG_FILE}" ]]; then
    source "${CFG_FILE}"
  else
    log "${RED}" "Could not read configuration file **${CFG_FILE}**"
    exit 1
  fi

  # keep track of the last executed command
  trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG

  [ "$#" -eq 0 ] && usage && exit 0

  cmd_type=$1

  while (( "$#" )); do
    case "$1" in
      -h|--help)
        usage
        return
        ;;
      rh)
        CONFIG=( ["CATALOG"]=${CATALOG_RH} ["DISPLAY"]=${DISPLAY_RH} ["NAME"]=${NAME_RH} ["PROJECT"]=${PROJECT_RH} ["IMAGE"]=${IMAGE_RH} )
        OPERATORS=("${OPERATORS_RH[@]}")
        break
        ;;
      co)
        CONFIG=( ["CATALOG"]=${CATALOG_CO} ["DISPLAY"]=${DISPLAY_CO} ["NAME"]=${NAME_CO} ["PROJECT"]=${PROJECT_CO} ["IMAGE"]=${IMAGE_CO} )
        OPERATORS=("${OPERATORS_CO[@]}")
        break
        ;;
      *) # unsupported params
        log "${RED}" "Error: Unsupported param $1"
        exit 1
        ;;
    esac
  done

  # Disable default sources (Configuring OperatorHub for restricted networks)
  # https://docs.openshift.com/container-platform/4.5/operators/admin/olm-restricted-networks.html#olm-restricted-networks-operatorhub_olm-restricted-networks
  # Configuring OperatorHub for restricted networks - Step 1
  log "${DARK_CYAN}" "Disabling the default sources"
  
  oc patch OperatorHub cluster --type json \
      -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

  # Get catalog images | Just for Info/Debug purpose
  log "${CYAN}" "Getting the catalog images"

  oc image info \
    registry.redhat.io/openshift4/ose-operator-registry:v4.5 \
      --filter-by-os=linux/amd64


  # Building an Operator catalog image
  # https://docs.openshift.com/container-platform/4.5/operators/admin/olm-restricted-networks.html#olm-building-operator-catalog-image_olm-restricted-networks
  log "${DARK_CYAN}" "Building the catalog image from **${CONFIG[CATALOG]}** catalog and pushing it to **${INTERNAL_REGISTRY}**"

  oc adm catalog build \
    --appregistry-org=${CONFIG[CATALOG]} \
    --from=registry.redhat.io/openshift4/ose-operator-registry:v4.5 \
    --to=${INTERNAL_REGISTRY}/olm/${CONFIG[CATALOG]}:v4.5-v1 \
    --filter-by-os=linux/amd64 \
    --insecure=true


  # Download catalog database
  # Configuring OperatorHub for restricted networks - Step 2 
  mkdir -p "${OUTPUTDIR}/database-${cmd_type}"
  log "${DARK_CYAN}" "Downloading the catalog database from **${INTERNAL_REGISTRY}/olm/${CONFIG[CATALOG]}:v4.5-v1** image"

  manifest_path=${OUTPUTDIR}/manifests-${cmd_type}

  oc adm catalog mirror \
    ${INTERNAL_REGISTRY}/olm/${CONFIG[CATALOG]}:v4.5-v1 \
    ${INTERNAL_REGISTRY} \
    --manifests-only \
    --to-manifests="${manifest_path}" \
    --path="/:${OUTPUTDIR}/database-${cmd_type}" \
    --filter-by-os=linux/amd64 \
    --insecure=true


  # Get operator catalog to mirror only a subset of the content
  # Configuring OperatorHub for restricted networks - Step 3 a
  log "${DARK_CYAN}" "Creating the custom/filtered mapping file from the current manifests stored in **${manifest_path}**"
  log "${CYAN}" "Serching by: ${OPERATORS[*]}"

  rm -f ${manifest_path}/mapping-filtered.txt

  # If you are unsure of the exact names and versions of the subset of images you want to mirror, use the following steps to find them
  # (Just check the `catalog.txt` file):
  sqlite3 "${OUTPUTDIR}/database-${cmd_type}/bundles.db" \
    "select operatorbundle_name from related_image group by operatorbundle_name;" \
      > "${manifest_path}/catalog.txt"

  # Install/filter operators from catalog
  for OPERATOR in "${OPERATORS[@]}"; do
    OPERATOR_IMAGES=(`sqlite3 ${OUTPUTDIR}/database-${cmd_type}/bundles.db \
      "select image from related_image where operatorbundle_name like '${OPERATOR}%';"`)

    for OPERATOR_IMAGE in "${OPERATOR_IMAGES[@]}"; do
      grep ${OPERATOR_IMAGE} "${manifest_path}/mapping.txt" \
        >> "${manifest_path}/mapping-filtered.txt"
    done
  done

  sort ${manifest_path}/mapping-filtered.txt | uniq -u > ${manifest_path}/mapping-filtered-no-duplicates.txt
  
  # Mirror filtered operators
  # Configuring OperatorHub for restricted networks - Step 3 b 
  log "${DARK_CYAN}" "Mirroring the images for the filtered operators from **${manifest_path}/mapping-filtered-no-duplicates.txt**"

  #Disable exit on error
  set +e

  #Using `--continue-on-error` instead of `--skip-missing` as it doesn't work as expected
  oc image mirror \
    --filename="${manifest_path}/mapping-filtered-no-duplicates.txt" \
    --filter-by-os=".*" \
    --continue-on-error \
    --insecure

  if [ $? -ne 0 ]
  then
    log "${YELLOW}" "Mirroring DONE with some errors probably due to some missing images"
  fi
  #Restore environment settings back
  set -$oldopt


  # Create disconnected source
  # Configuring OperatorHub for restricted networks - Step 5
  log "${DARK_CYAN}" "Creating the disconnected source from **${OUTPUTDIR}/catalog-source-${cmd_type}.yml** yaml file"

  cs_template_file="${OUTPUTDIR}/catalog-source-${cmd_type}.yml"
  create_template "${cs_template_file}"
  oc apply -f "${cs_template_file}"

  
  # Apply mirror configuration
  # Configuring OperatorHub for restricted networks - Step 4
  log "${DARK_CYAN}" "Applying the mirror configuration from **${manifest_path}/imageContentSourcePolicy.yaml** yaml file"
  oc apply -f ${manifest_path}/imageContentSourcePolicy.yaml

  log "${GREEN}" "*** DONE - ALL OK ***"

}

main "$@"

exit 0
