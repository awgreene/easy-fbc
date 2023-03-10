#!/usr/bin/env bash

################################################################################
# InstallPlan Fixer                                                            #
#                                                                              #
# This script aims to fix fault install plans caused by a poluted olm index.   #
# KCS: https://access.redhat.com/articles/7000167                              #   
# Version: v1.0.0                                                              #
#                                                                              #
# Change Log:                                                                  #
# ---------------------------------------------------------------------------- #
# v1.0.0 - Initial release.                                                    #
#                                                                              #
################################################################################

set -e

####################
# Helper Constants #
####################
# colors to make it nice
RED_COLOR='\033[0;31m'
NO_COLOR='\033[0m'
GREEN_CHECKMARK="\033[32m\xE2\x9C\x94\033[0m"
RED_CROSS="\033[31m\xE2\x9D\x8C\033[0m"

# install plan table column widths
MAX_NS_W=30
MAX_IP_W=13
MAX_ST_W=10
MAX_IMG_W=80

# KCS article link
KCS_LINK="https://access.redhat.com/articles/7000167"

# unpack job namespaces
UNPACK_NAMESPACE="openshift-marketplace"

# Backup directory for install plans that are being fixed
BACKUP_DIR=$(mktemp -d /tmp/rh-ipfixer-backup.XXXXXXXXXX)

# Script log file for troubleshooting
LOG_FILE=$(mktemp /tmp/rh-ipfixer.XXXXXXXXXX.log)

# Default behavior flags
DEBUG=false

####################
# Helper Functions #
####################

#############################################################
# red_hat prints redhat ascii art in red
#############################################################
function red_hat() {                                                                
  echo -e "\e[31m                               88 88                              
                               88 88                       ,d     
                               88 88                       88     
8b,dPPYba,  ,adPPYba,  ,adPPYb,88 88,dPPYba,  ,adPPYYba, MM88MMM  
88P'   \"Y8 a8P_____88 a8\"    \`Y88 88P'    \"8a \"\"     \`Y8   88     
88         8PP\"\"\"\"\"\"\" 8b       88 88       88 ,adPPPPP88   88     
88         \"8b,   ,aa \"8a,   ,d88 88       88 88,    ,88   88,    
88          \`\"Ybbd8\"'  \`\"8bbdP\"Y8 88       88 \`\"8bbdP\"Y8   \"Y888  
                                                                   \e[0m"
echo -e "For more information: ${KCS_LINK}"
}

#############################################################
# get_affected_ips returns the list of faulty install plans
#############################################################
function get_affected_ips() {
  echo -n "$(\
      oc get --no-headers \
         --all-namespaces \
         installplans.operators.coreos.com \
         -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,BundleLookupPath:.status.bundleLookups[].path' | \
         grep 'NAMESPACE\|Failed.*registry[.]stage[.]redhat[.]io'\
  )"
}

#############################################################
# truncate_to_width takes two parameters:
# $1 -> string to be truncated
# $2 -> the width to truncate it to
# Returns: 
# $1, if len($1) < $2 (width)
# A truncated string of length $2 suffixed by ellipeses
# Example:
# truncate_to_width "hello world!" 12 -> "hello"
# truncate_to_width "hello world" 11 ->  "hello wo..."
#############################################################
function truncate_to_width() {
  local str="$1"
  local width=$2
  echo "$str" | awk -v len="$width" '{ if (length($0) > len) print substr($0, 1, len-3) "..."; else print $0 }'
}

#############################################################
# foreach_ip takes two parameters:
# $1 -> a string of output from the faulty ips query
# several lines in the format: 
#  namespace installplan status image
# $2 -> the name of a function to execute over installplan
# Note: the function denoted by $2 takes 4 parameters: 
# namespace, installplan, status, and image
# Note: additional parameters will be passed to the underlying
# function
# The function denoted by $2 will be executed for each
# installplan
#############################################################
function foreach_ip() {
  local ips="$1"
  local fn=$2
  shift 2
  while IFS=" " read -r namespace install_plan status image; do
    $fn "$namespace" "$install_plan" "$status" "$image" "$@"
  done < <(echo ${ips})
}

#############################################################
# min takes two parameters:
# $1 -> an integer
# $2 -> another integer
# Returns: the min between the two integers
#############################################################
function min() {
  local a=${1-0}
  local b=${2-0}
  # Compare the variables and store the maximum value in a third variable
  if [ "$a" -lt "$b" ]; then
    echo "$a"
  else
    echo "$b"
  fi
}

#############################################################
# print_ip_table_row takes 4 parameters:
# $1 -> namespace
# $2 -> install plan
# $3 -> status
# $4 -> image
# $5 -> namespace column width
# $6 -> install plan column width
# $7 -> status column width
# $8 -> image column width
# The function prints a formatted row with this information
# column values that are greater than the column width are
# truncated to size
#############################################################
function print_ip_table_row() {
  local ns_w="${5-${MAX_NS_W}}"
  local ip_w="${6-${MAX_IP_W}}"
  local st_w="${7-${MAX_ST_W}}"
  local ig_w="${8-${MAX_IMG_W}}"

  # merge namespace and installplan
  local ip_w=$((ns_w + ip_w + 1))

  local install_plan=$(truncate_to_width "$1/$2" ${ip_w})
  local status=$(truncate_to_width "$3" ${st_w})
  local image=$(truncate_to_width "$4" ${ig_w})
  local image_color=${NO_COLOR}

  local status_color=${NO_COLOR}
  local image_color=${NO_COLOR}

  if [[ $(echo ${status} | tr '[:upper:]' '[:lower:]') == "failed" ]]; then
    status_color=${RED_COLOR}
  fi

  if [[ $image =~ registry[.]stage[.]redhat[.]io ]]; then
    image_color=${RED_COLOR}
  fi

  printf "* %-${ip_w}.${ip_w}s (bundle image: ${image_color}%-${ig_w}.${ig_w}s${NO_COLOR})\n" "$install_plan" "$image"
}

#############################################################
# print_ip_table_row takes 1 parameter:
# $1 -> a string of output from the faulty ips query
# several lines in the format: 
#  namespace installplan status image
# The function prints a formatted table with each of the
# problematic install plans
#############################################################
function print_faulty_installplan_table() {
  local ips="$1"

  # get number of faulty install plans
  local num_ips=$(echo "$1" | wc -l)

  if [ $num_ips -eq 0 ]; then
    echo -e "No faulty install plans found."
    exit 0
  fi

  echo -e "\nFound ${num_ips} faulty install plan(s):"

  # calculate the length of the longest string for each of the
  # namespace, install plan, status, image columns
  local ns_w=$(min "$(echo -e "$ips" | awk '{ print length($1) }' | sort -nr | head -n 1)" "${MAX_NS_W}")
  local ip_w=$(min "$(echo -e "$ips" | awk '{ print length($2) }' | sort -nr | head -n 1)" "${MAX_IP_W}")
  local st_w=$(min "$(echo -e "$ips" | awk '{ print length($3) }' | sort -nr | head -n 1)" "${MAX_ST_W}")
  local ig_w=$(min "$(echo -e "$ips" | awk '{ print length($4) }' | sort -nr | head -n 1)" "${MAX_IMG_W}")

  # print faulty ip table with header
  foreach_ip "${ips}" print_ip_table_row "${ns_w}" "${ip_w}" "${st_w}" "${ig_w}"
}


#############################################################
# print_ip_table_row takes 3 parameters:
# $1 -> namespace
# $2 -> install plan
# $3 -> image
# Returns: unpack job if found or empty string otherwise
#############################################################
function get_ip_unpack_job_id() {
  local namespace="$1"
  local ip="$2"
  local image="$3"

  # regex to extract unpack job id from install plan status
  local unpack_job_regex=".*Unpack pod\(openshift-marketplace\/(.*)\) container\(pull\) .*\"${image}\""
  local ip_status="$(oc get ip -n "${namespace}" "${ip}" -o jsonpath='{.status.bundleLookups[*].conditions[?(@.type=="BundleLookupPending")].message})')"
  if [[ "${ip_status}" =~ ${unpack_job_regex} ]]; then
    echo -e "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

#############################################################
# check_or_cross takes 2 parameters:
# $1 -> return value ($?) from a command
# $2 -> error message
# A green checkmark will be printed if the return value is 0
# Otherwise, a red cross will be printed followed by the
# error message in a new line
#############################################################
function check_or_cross() {
  ret="$1"
  err="$2"

  if [ "$1" -eq 0 ]; then
    echo -e "${GREEN_CHECKMARK}"
  else
    echo -e "${RED_CROSS}"
    echo -e "\nError: ${err_msg}"
    exit 1
  fi
}

function get_ip_sub {
  local namespace="$1"
  local ip="$2"

}

#############################################################
# fix_faulty_ip takes 4 parameters:
# $1 -> namespace
# $2 -> install plan
# $3 -> status
# $4 -> image
# It executes the steps necessary to fix the faulty ips
#############################################################
function fix_faulty_ip() {
  local namespace="$1"
  local ip="$2"
  local status="$3"
  local image="$4"

  echo -e "Fixing install plan \e[4m${namespace}/${ip}\e[0m..."
  echo -ne "  * Getting unpack job id..."
  local unpack_job_id="$(echo -n "${image}" | sha256sum -t | cut -c1-63)"
  if [ ! -z "$unpack_job_id" ]; then
    echo -e "${GREEN_CHECKMARK}"
  else
    echo -e "${RED_CROSS}"
    echo -e "\nError: Could not identify unpack job id for install plan ${namespace}/${ip}"
    exit 1
  fi

  echo -ne "  * Getting subscription..."
  read sub_ns sub_name <<< "$(kubectl get subscription --all-namespaces -o json | \
    jq ".items[] | select(.status.installPlanRef.name == \"${ip}\" and .status.installPlanRef.namespace == \"${namespace}\")" | \
    jq -r '.metadata.namespace + " " + .metadata.name')"
  if [ -z "$sub_ns" ] || [ -z "$sub_name" ]; then
    echo -e "${RED_CROSS}"
    echo -e "Error: could not determine subscription namespaces and name"
    exit 1
  else
    echo -e "${GREEN_CHECKMARK}"
  fi

  local backup_ip="${BACKUP_DIR}/${ip}.yaml"
  local backup_job="${BACKUP_DIR}/${ip}.yaml"
  local backup_cnfmap="${BACKUP_DIR}/${ip}.yaml"

  echo -ne "  * Backing up faulty install plan "${backup_ip}""...
  local err=$(kubectl get ip -n "${namespace}" "${ip}" -o yaml > "${backup_ip}" 2>&1 >/dev/null)
  check_or_cross "$?" "${err}"

  echo -ne "  * Backing up unpack job to "${backup_job}""...
  local err=$(kubectl get job -n "${UNPACK_NAMESPACE}" "${unpack_job_id}" -o yaml > "${backup_job}" 2>&1 >/dev/null)
  check_or_cross "$?" "${err}"

  echo -ne "  * Backing up job configmap to "${backup_cnfmap}""...
  local err=$(kubectl get ip -n "${UNPACK_NAMESPACE}" "${unpack_job_id}" -o yaml > "${backup_cnfmap}" 2>&1 >/dev/null)
  check_or_cross "$?" "${err}"

  # echo -ne "  * Deleting job ${unpack_job_id}..."
  # local err=$(kubectl delete job -n "${UNPACK_NAMESPACE}" "${unpack_job_id}")
  # check_or_cross "$?" "${err}"

  # echo -ne "Deleting configmap ${unpack_job_id}..."
  # local err=$(kubectl delete configmap -n "${UNPACK_NAMESPACE}" "${unpack_job_id}")
  # check_or_cross "$?" "${err}"

  # echo -ne "Deleting install plan ${unpack_job_id}..."
  # local err=$(kubectl delete job -n "${UNPACK_NAMESPACE}" "${unpack_job_id}")
  # check_or_cross "$?" "${err}"
}

# top-level function called with --check
function check_faulty_ips() {
  ensure_catsrc
  local affected_ips="$(get_affected_ips)"
  echo "Running faulty install plan check."
  echo "Looking for install plans whose unpack job failed due to the bundle image being in the staging repository."
  print_faulty_installplan_table "${affected_ips}"
}

# top-level function called with --fix
function fix_faulty_ips() {
  ensure_catsrc
  local affected_ips="$(get_affected_ips)"
  echo "Fixing faulty install plans."
  echo "Looking for install plans whose unpack job failed due to the bundle image being in the staging repository."
  print_faulty_installplan_table "${affected_ips}"

  # Prompt the user for confirmation
  echo ""
  echo -e "For each faulty install plan, the following operations will be executed to correct the fault: "
  echo -e "  1) The install plan's unpack job id will be deduced from the install plans status"
  echo -e "  2) The install plan and associated unpack job and configmap will be \e[4mbacked-up\e[0m"
  echo -e "  3) The install plan and associated unpack job and configmap will be \e[4mdeleted\e[0m"
  echo -e "Once this is done, OLM will create a new, corrected, install plan"
  read -p "Proceed with fixing the faulty install plans? [y/N]: " response
  # Check the response
  if [[ ! "$response" =~ ^[yY]$ ]]; then
    echo "Aborting..."
    exit 1
  fi
  echo ""
  # Fix ips
  foreach_ip "${affected_ips}" fix_faulty_ip
}

# sets up the script environment to keep a log of the execution
function setup() {
  # Redirect standard output and standard error to the log file
  exec &> >(tee -a "$LOG_FILE")

  # Switch debug on if --debug flag is passed in
  if [ "$DEBUG" = true ]; then
    set -x
  fi

  # Set up the error handler
  function handle_error {
    echo ""
    echo "Execution was logged in: $LOG_FILE"
    echo "Original related kubernetes resources, if any, were backed up at: $BACKUP_DIR"
    exit 1
  }
  trap 'handle_error' ERR
  trap 'handle_error' EXIT 1
}

# ensures the catalog soruce has been correctly updated
function ensure_catsrc {
  echo -e "Ensuring marketplace catalog sources have been updated with the correct image...${GREEN_CHECKMARK}"
}

####################
#   Main Script    #
####################

red_hat
echo ""

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
      -d|--debug) DEBUG=true;;
      -v|--version) echo "Version: v1.0.0"; exit;;
      -f|--fix) setup; fix_faulty_ips;;
      -c|--check) setup; check_faulty_ips;;
      -h|--help)
          echo "Usage: $0 [options]"
          echo ""
          echo "Options:"
          echo "  -c, --check        Check for and list faulty install plans."
          echo "  -f, --fix          Fix faulty install plans."
          echo "  -d, --debug        Output all commands and their output to the screen for debugging purposes."
          echo "  -v, --version      Display the current script version."
          echo "  -h, --help         Display this help message."
          echo ""
          echo "For more information, please check: ${KCS_LINK}"
          exit;;
      *) echo "Unknown parameter passed: $1"; exit 1;;
  esac
  shift
done
