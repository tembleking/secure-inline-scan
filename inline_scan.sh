#!/usr/bin/env bash

set -eou pipefail

########################
### GLOBAL VARIABLES ###
########################

# If using a locally built stateless CI container, export SYSDIG_CI_IMAGE=<image_name>.
# This will override the image name from Dockerhub.
INLINE_SCAN_IMAGE="${SYSDIG_CI_IMAGE:-docker.io/anchore/inline-scan:v0.5.0}"
DOCKER_NAME="${RANDOM:-temp}-inline-anchore-engine"
DOCKER_ID=""
ANALYZE=false
VULN_SCAN=false
CREATE_CMD=()
RUN_CMD=()
COPY_CMDS=()
IMAGE_NAMES=()
IMAGE_FILES=()
SCAN_IMAGES=()
FAILED_IMAGES=()
VALIDATED_OPTIONS=""
# Vuln scan option variable defaults
DOCKERFILE="./Dockerfile"
POLICY_BUNDLE="./policy_bundle.json"
TIMEOUT=300
VOLUME_PATH="/tmp/"
# Analyzer option variable defaults
SYSDIG_SCANNING_URL="http://localhost:9040/api/scanning"
SYSDIG_ANCHORE_URL="http://localhost:9040/api/scanning/v1/anchore"
SYSDIG_ANNOTATIONS="foo=bar"
IMAGE_DIGEST_SHA="sha256:123456890abcdefg"
SYSDIG_IMAGE_ID="123456890abcdefg"
MANIFEST_FILE="./manifest.json"
POST_CALL_RETRIES=3
GET_CALL_RETRIES=100

display_usage() {
cat << EOF

Sysdig Inline Scanner/Analyzer --

  Wrapper script for performing vulnerability scan or image analysis on local docker images, utilizing the Sysdig inline_scan container.
  For more detailed usage instructions use the -h option after specifying scan or analyze.

    Usage: ${0##*/} <analyze> [ OPTIONS ]

EOF
}

display_usage_analyzer() {
cat << EOF

Sysdig Inline Analyzer --

  Script for performing analysis on local docker images, utilizing the Sysdig analyzer subsystem.
  After image is analyzed, the resulting image archive is sent to a remote Sysdig installation
  using the -s <URL> option. This allows inline_analysis data to be persisted & utilized for reporting.

  Images should be built & tagged locally.

    Usage: ${0##*/} analyze -s <SYSDIG_REMOTE_URL> -k <API Token> [ OPTIONS ] <FULL_IMAGE_TAG>

      -s <TEXT>  [required] URL to Sysdig Secure URL (ex: -s 'https://secure-sysdig.com')
      -k <TEXT>  [required] API token for Sysdig Scanning auth (ex: -k '924c7ddc-4c09-4d22-bd52-2f7db22f3066')
      -a <TEXT>  [optional] Add annotations (ex: -a 'key=value,key=value')
      -f <PATH>  [optional] Path to Dockerfile (ex: -f ./Dockerfile)
      -i <TEXT>  [optional] Specify image ID used within Sysdig (ex: -i '<64 hex characters>')
      -m <PATH>  [optional] Path to Docker image manifest (ex: -m ./manifest.json)
      -t <TEXT>  [optional] Specify timeout for image analysis in seconds. Defaults to 300s. (ex: -t 500)
      -d <TEXT>  [optional] Specify number of retries to POST analysis result to Secure backend. Defaults to 3 attempts, max 10. (ex: -d 3)
      -r <TEXT>  [optional] Specify number of retries to GET the scan results from Secure backend. Defaults to 100 attempts, max 300. (ex: -r 100)
      -P  [optional] Pull docker image from registry
      -V  [optional] Increase verbosity

EOF
}

main() {
    trap 'cleanup' EXIT ERR SIGTERM
    trap 'interupt' SIGINT

    if [[ "$#" -lt 1 ]]; then
        display_usage >&2
        printf '\n\t%s\n\n' "ERROR - must specify operation ('analyze')" >&2
        exit 1
    fi
    if [[ "$1" == 'help' ]]; then
        display_usage >&2
	exit 1
    elif [[ "$1" == 'analyze' ]]; then
        shift "$((OPTIND))"
        ANALYZE=true
        get_and_validate_analyzer_options "$@"
        get_and_validate_images "${VALIDATED_OPTIONS}"
        prepare_inline_container
        CREATE_CMD+=('analyze')
        RUN_CMD+=('analyze')
        start_analysis
    fi
}

get_and_validate_analyzer_options() {
    #Parse options
    while getopts ':s:k:r:u:p:a:d:f:i:m:t:PgVh' option; do
        case "${option}" in
            s  ) s_flag=true; SYSDIG_SCANNING_URL="${OPTARG%%}"/api/scanning/v1; SYSDIG_ANCHORE_URL="${SYSDIG_SCANNING_URL}"/anchore;;
            k  ) k_flag=true; SYSDIG_API_TOKEN="${OPTARG}";;
            a  ) a_flag=true; SYSDIG_ANNOTATIONS="${OPTARG}";;
            f  ) f_flag=true; DOCKERFILE="${OPTARG}";;
            i  ) i_flag=true; SYSDIG_IMAGE_ID="${OPTARG}";;
            m  ) m_flag=true; MANIFEST_FILE="${OPTARG}";;
            t  ) t_flag=true; TIMEOUT="${OPTARG}";;
            d  ) d_flag=true; POST_CALL_RETRIES="${OPTARG}";;
            r  ) r_flag=true; GET_CALL_RETRIES="${OPTARG}";;
            P  ) P_flag=true;;
            V  ) V_flag=true;;
            h  ) display_usage_analyzer; exit;;
            \? ) printf "\n\t%s\n\n" "Invalid option: -${OPTARG}" >&2; display_usage_analyzer >&2; exit 1;;
            :  ) printf "\n\t%s\n\n%s\n\n" "Option -${OPTARG} requires an argument." >&2; display_usage_analyzer >&2; exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"

    # Check for invalid options
    if [[ ! $(which docker) ]]; then
        printf '\n\t%s\n\n' 'ERROR - Docker is not installed or cannot be found in $PATH' >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${#@}" -gt 1 ]]; then
        printf '\n\t%s\n\n' "ERROR - only 1 image can be analyzed at a time" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${#@}" -lt 1 ]]; then
        printf '\n\t%s\n\n' "ERROR - must specify an image to analyze" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ ! "${s_flag:-}" ]]; then
        printf '\n\t%s\n\n' "ERROR - must provide an Sysdig Secure endpoint" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${s_flag:-}" ]] && [[ ! "${k_flag:-}" ]]; then
        printf '\n\t%s\n\n' "ERROR - must provide the Sysdig Secure API token" >&2
        display_usage_analyzer >&2
        exit 1
    elif ! curl -k -s --fail -H "Authorization: Bearer ${SYSDIG_API_TOKEN}" "${SYSDIG_SCANNING_URL}/policies" > /dev/null; then
        printf '\n\t%s\n\n' "ERROR - invalid combination of sysdig secure endpoint : token provided - ${SYSDIG_SCANNING_URL} : ${SYSDIG_API_TOKEN}" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${a_flag:-}" ]]; then
        # transform all commas to spaces & cast to an array
        local annotation_array=(${SYSDIG_ANNOTATIONS//,/ })
        # get count of = in annotation string
        local number_keys=${SYSDIG_ANNOTATIONS//[^=]}
        # compare number of elements in array with number of = in annotation string
        if [[ "${#number_keys}" -ne "${#annotation_array[@]}" ]]; then
            printf '\n\t%s\n\n' "ERROR - ${SYSDIG_ANNOTATIONS} is not a valid input for -a option" >&2
            display_usage_analyzer >&2
            exit 1
        fi
    elif [[ "${f_flag:-}" ]] && [[ ! -f "${DOCKERFILE}" ]]; then
        printf '\n\t%s\n\n' "ERROR - Dockerfile: ${DOCKERFILE} does not exist" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${m_flag:-}" ]] && [[ ! -f "${MANIFEST_FILE}" ]];then
        printf '\n\t%s\n\n' "ERROR - Manifest: ${MANIFEST_FILE} does not exist" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${t_flag:-}" ]] && [[ ! "${TIMEOUT}" =~ ^[0-9]+$ ]]; then
        printf '\n\t%s\n\n' "ERROR - timeout must be set to a valid integer" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${d_flag:-}" ]] && [[ ! "${POST_CALL_RETRIES}" =~ ^[0-9]+$ ]]; then
        printf '\n\t%s\n\n' "ERROR - number of POST call retries must be set to a valid integer" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${d_flag:-}" ]] && [[ "${POST_CALL_RETRIES}" -gt 10 ]]; then
        printf '\n\t%s\n\n' "ERROR - max number of retries for POST call is 10" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${r_flag:-}" ]] && [[ ! "${GET_CALL_RETRIES}" =~ ^[0-9]+$ ]]; then
        printf '\n\t%s\n\n' "ERROR - number of GET call retries must be set to a valid integer" >&2
        display_usage_analyzer >&2
        exit 1
    elif [[ "${r_flag:-}" ]] && [[ "${GET_CALL_RETRIES}" -gt 300 ]]; then
        printf '\n\t%s\n\n' "ERROR - max number of retries for GET call is 300" >&2
        display_usage_analyzer >&2
        exit 1
    fi

    if [[ "${V_flag:-}" ]]; then
        set -x
    fi

    VALIDATED_OPTIONS="$@"
}

get_and_validate_images() {
    # Add all unique positional input params to IMAGE_NAMES array
    for i in $@; do
        if [[ ! "${IMAGE_NAMES[@]:-}" =~ "$i" ]]; then
            IMAGE_NAMES+=("$i")
        fi
    done

    # Make sure all images are available locally, add to FAILED_IMAGES array if not
    for i in "${IMAGE_NAMES[@]-}"; do
        if ([[ "${p_flag:-false}" == true ]] && [[ "${VULN_SCAN:-false}" == true ]]) || [[ "${P_flag:-false}" == true ]]; then
            echo "Pulling image -- $i"
            docker pull $i || true
        fi

        docker inspect "$i" &> /dev/null || FAILED_IMAGES+=("$i")

        if [[ ! "${FAILED_IMAGES[@]:-}" =~ "$i" ]]; then
            SCAN_IMAGES+=("$i")
        fi
    done

    # Give error message on any invalid image names
    if [[ "${#FAILED_IMAGES[@]}" -gt 0 ]]; then
        printf '\n%s\n\n' "WARNING - Please pull remote image, or build/tag all local images before attempting analysis again" >&2

        if [[ "${#FAILED_IMAGES[@]}" -ge "${#IMAGE_NAMES[@]}" ]]; then
            printf '\n\t%s\n\n' "ERROR - no local docker images specified in script input: ${0##*/} ${IMAGE_NAMES[*]}" >&2
            display_usage >&2
            exit 1
        fi

        for i in "${FAILED_IMAGES[@]}"; do
            printf '\t%s\n' "Could not find image locally -- $i" >&2
        done
    fi
}

prepare_inline_container() {
    # Check if env var is overriding which inline-scan image to utilize.
    if [[ -z "${SYSDIG_CI_IMAGE-docker.io/anchore/inline-scan:v0.5.0}" ]]; then
        printf '\n%s\n' "Pulling ${INLINE_SCAN_IMAGE}"
        docker pull "${INLINE_SCAN_IMAGE}"
    else
        printf '\n%s\n' "Using local image for scanning -- ${INLINE_SCAN_IMAGE}"
    fi

    # setup command arrays to eval & run after adding all required options
    CREATE_CMD=('docker create --name "${DOCKER_NAME}"')
    RUN_CMD=('docker run -i --name "${DOCKER_NAME}"')

    if [[ "${t_flag-""}" ]]; then
        CREATE_CMD+=('-e TIMEOUT="${TIMEOUT}"')
        RUN_CMD+=('-e TIMEOUT="${TIMEOUT}"')
    fi
    if [[ "${V_flag-""}" ]]; then
        CREATE_CMD+=('-e VERBOSE=true')
        RUN_CMD+=('-e VERBOSE=true')
    fi
    if [[ "${v_flag-""}" ]]; then
        printf '\n%s\n' "Creating volume mount -- ${VOLUME_PATH}:/anchore-engine"
        CREATE_CMD+=('-v "${VOLUME_PATH}:/anchore-engine:rw"')
    fi

    CREATE_CMD+=('"${INLINE_SCAN_IMAGE}"')
    RUN_CMD+=('"${INLINE_SCAN_IMAGE}"')
}

start_analysis() {
    # Prepare commands for container creation & copying all files to container.
    
    for i in "${SCAN_IMAGES[@]}"; do
        # Fetch the individual digest for each succesful image and add it to the list of digests
        IMAGE_DIGEST=$(docker image inspect "$i" -f "{{.RepoDigests}}" | cut -f2 -d "@" | cut -f1 -d "]")
        IMAGE_DIGEST_SHA=$IMAGE_DIGEST        
    done

    CREATE_CMD+=('-d "${IMAGE_DIGEST_SHA}"')
    
    if [[ "${i_flag-""}" ]]; then
        CREATE_CMD+=('-i "${SYSDIG_IMAGE_ID}"')
    fi
    if [[ "${a_flag-""}" ]]; then
        CREATE_CMD+=('-a "${SYSDIG_ANNOTATIONS}"')
    fi
    if [[ "${g_flag-""}" ]]; then
        CREATE_CMD+=('-g')
    fi
    if [[ "${m_flag-""}" ]]; then
        CREATE_CMD+=('-m "${MANIFEST_FILE}"')
        COPY_CMDS+=('docker cp "${MANIFEST_FILE}" "${DOCKER_NAME}:/anchore-engine/$(basename ${MANIFEST_FILE})";')
    fi
    if [[ "${f_flag-""}" ]]; then
        CREATE_CMD+=('-f "${DOCKERFILE}"')
        COPY_CMDS+=('docker cp "${DOCKERFILE}" "${DOCKER_NAME}:/anchore-engine/$(basename ${DOCKERFILE})";')
    fi

    # finally, get the account from Sysdig for the input username
    mkdir -p /tmp/sysdig
    HCODE=$(curl -sSk --output /tmp/sysdig/sysdig_output.log --write-out "%{http_code}" -H "Authorization: Bearer ${SYSDIG_API_TOKEN}" "${SYSDIG_ANCHORE_URL%%/}/account")
    if [[ "${HCODE}" == 200 ]] && [[ -f "/tmp/sysdig/sysdig_output.log" ]]; then
	ANCHORE_ACCOUNT=$(cat /tmp/sysdig/sysdig_output.log | grep '"name"' | awk -F'"' '{print $4}')
	CREATE_CMD+=('-u "${ANCHORE_ACCOUNT}"')
    else
	printf '\n\t%s\n\n' "ERROR - unable to fetch account information from anchore-engine for specified user"
	if [ -f /tmp/sysdig/sysdig_output.log ]; then
	    printf '%s\n\n' "***SERVICE RESPONSE****">&2
	    cat /tmp/sysdig/sysdig_output.log >&2
	    printf '\n%s\n' "***END SERVICE RESPONSE****" >&2
	fi
	exit 1
    fi

    CREATE_CMD+=("${SCAN_IMAGES[*]}")
    DOCKER_ID=$(eval "${CREATE_CMD[*]}")
    eval "${COPY_CMDS[*]-}"
    save_and_copy_images
    echo
    docker start -ia "${DOCKER_NAME}"

    local analysis_archive_name="${IMAGE_FILES[*]%.tar}-archive.tgz"
    # copy image analysis archive from inline_scan containter to host & curl to remote anchore-engine endpoint
    docker cp "${DOCKER_NAME}:/anchore-engine/image-analysis-archive.tgz" "/tmp/sysdig/${analysis_archive_name}"

    if [[ -f "/tmp/sysdig/${analysis_archive_name}" ]]; then
        printf '%s\n' " Analysis complete!"
        printf '\n%s\n' "Sending analysis archive to ${SYSDIG_SCANNING_URL%%/}"
    else
        printf '\n\t%s\n\n' "ERROR - analysis file invalid: /tmp/sysdig/${analysis_archive_name}. An error occured during analysis."  >&2
        display_usage_analyzer >&2
        exit 1
    fi

    # Posting the archive to the secure backend
    for ((i=0;  i<${POST_CALL_RETRIES}; i++)); do
        HCODE=$(curl -sSk --output /tmp/sysdig/sysdig_output.log --write-out "%{http_code}" -H "Content-Type: multipart/form-data" -H "Authorization: Bearer ${SYSDIG_API_TOKEN}" -F "archive_file=@/tmp/sysdig/${analysis_archive_name}" "${SYSDIG_SCANNING_URL}/import/images")
        if [ ! -z  "$HCODE" ]; then
            break
        fi
        echo -n "." && sleep 2
    done

	if [[ "${HCODE}" != 200 ]]; then
	    printf '\n\t%s\n\n' "ERROR - unable to POST ${analysis_archive_name} to ${SYSDIG_SCANNING_URL%%/}/import/images" >&2
	    if [ -f /tmp/sysdig/sysdig_output.log ]; then
		printf '%s\n\n' "***SERVICE RESPONSE****">&2
		cat /tmp/sysdig/sysdig_output.log >&2
		printf '\n%s\n' "***END SERVICE RESPONSE****" >&2
	    fi
	    exit 1
	fi

    FULLTAG="${SCAN_IMAGES[0]}"
    check_status_with_digest
}

check_status_with_digest() {
    # Fetching the result of each scanned digest
    for ((i=0;  i<${GET_CALL_RETRIES}; i++)); do
        status=$(curl -s -k  --header "Content-Type: application/json" -H "Authorization: Bearer ${SYSDIG_API_TOKEN}" "${SYSDIG_SCANNING_URL}/images/${IMAGE_DIGEST}/checkSummary?tag=$FULLTAG" | grep "status" | cut -d : -f 2 | awk -F\" '{ print $2 }')
        if [ ! -z  "$status" ]; then
            break
        fi
        echo -n "." && sleep 1
    done
 
    printf "Scan Report - \n"
    curl -s -k --header "Content-Type: application/json" -H "Authorization: Bearer ${SYSDIG_API_TOKEN}" "${SYSDIG_SCANNING_URL}/images/${IMAGE_DIGEST}/checkSummary?tag=$FULLTAG"

    if [[ "${status}" = "pass" ]]; then
        printf "\nStatus is pass\n"
        exit 0
    else
        printf "\nStatus is fail\n"
        exit 1
    fi
}

save_and_copy_images() {
    # Save all image files to /tmp and copy to created container
    for image in "${SCAN_IMAGES[@]-}"; do
        local base_image_name="${image##*/}"
        echo "Saving ${image} for local analysis"
        local save_file_name="${base_image_name}.tar"
        IMAGE_FILES+=("$save_file_name")

        if [[ "${v_flag-""}" ]]; then
            local save_file_path="${VOLUME_PATH}/${save_file_name}"
        else
            mkdir -p /tmp/sysdig
            local save_file_path="/tmp/sysdig/${save_file_name}"
        fi

        # If image is passed without a tag, append :latest to docker save to prevent skopeo manifest error
        if [[ ! "${image}" =~ [:]+ ]]; then
            docker save "${image}:latest" -o "${save_file_path}"
        else
            docker save "${image}" -o "${save_file_path}"
        fi

        if [[ -f "${save_file_path}" ]]; then
            chmod +r "${save_file_path}"
            printf '%s' "Successfully prepared image archive -- ${save_file_path}"
        else
            printf '\n\t%s\n\n' "ERROR - unable to save docker image to ${save_file_path}." >&2
            display_usage >&2
            exit 1
        fi

        if [[ ! "${v_flag-""}" ]]; then
            docker cp "${save_file_path}" "${DOCKER_NAME}:/anchore-engine/${save_file_name}"
            rm -f "${save_file_path}"
        fi
    done
}

interupt() {
    cleanup 130
}

cleanup() {
    local ret="$?"
    if [[ "${#@}" -ge 1 ]]; then
        local ret="$1"
    fi
    set +e

    if [[ -z "${DOCKER_ID-""}" ]]; then
        DOCKER_ID="${DOCKER_NAME:-$(docker ps -a | grep 'inline-anchore-engine' | awk '{print $1}')}"
    fi

    for id in ${DOCKER_ID}; do
        local -i timeout=0
        while (docker ps -a | grep "${id:0:10}") > /dev/null && [[ "${timeout}" -lt 12 ]]; do
            docker kill "${id}" &> /dev/null
            docker rm "${id}" &> /dev/null
            printf '\n%s\n' "Cleaning up docker container: ${id}"
            ((timeout=timeout+1))
            sleep 5
        done

        if [[ "${timeout}" -ge 12 ]]; then
            exit 1
        fi
        unset DOCKER_ID
    done

    if [[ "${#IMAGE_FILES[@]}" -ge 1 ]] || [[ -f /tmp/sysdig/sysdig_output.log ]]; then
        if [[ -d "/tmp/sysdig" ]]; then
            rm -rf "/tmp/sysdig"
        fi
    fi

    exit "${ret}"
}

main "$@"

