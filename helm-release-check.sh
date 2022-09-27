#!/bin/bash

UNRECOVERABLE_STATUS='Pending|ImagePullBackOff|CreateContainerConfigError|CrashLoopBackOff'
DEFAULT_FILTER_LABEL='app.kubernetes.io/name'

function help()
{
  echo "Usage: helm-release-check.sh [ -r, the release name, default: \"\"]
        [ -n, the release namespace, default \"\" ]
        [ -h | --help ]"
  echo "Example: ./helm-release-check.sh -r hello-world -n default"
  exit 2
}

function release_existence_check()
{
  echo "--Check if release exists"

  for wait_count in {1..3}; do
    found_release=$(helm list -q -n "${arg_ns}" --filter="^${arg_release_name}\$")
    if [[ $? -ne 0 ]]; then
      echo "Check failed: helm list failed"
      break
    fi 

    if [[ $found_release == "" ]]; then
      echo "Check failed: release $arg_release_name does not exist in namespace $arg_ns. Retrying..."
      sleep 2
    else
      echo "Check passed."
      echo 
      return
    fi
  done

  echo "Release failed!"
  exit 1
}

function helm_status_check()
{
  echo "--Check if helm status is deployed"

  for wait_count in {1..3}; do
    helm_status=$(helm status -n "${arg_ns}" "${arg_release_name}"  | grep 'STATUS' | awk '{print $2}')
    if [[ $? -ne 0 ]]; then
      echo "Check failed: helm status failed"
      break
    fi

    if [[ $helm_status != "deployed" ]]; then
      echo "Check failed: helm status is ${helm_status}. Retrying..."
      sleep 2
    else
      echo "Check passed."
      echo
      return
    fi
  done

  echo "Retry failed!"
  exit 1
}

function rollout_check()
{
  echo "--Check if all resources are deployed and available/ready"

  for wait_count in {1..60}; do
    check_resources=$(kubectl get statefulsets,deployments -n ${arg_ns} --no-headers -l ${arg_label}=${arg_release_name} 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "Check failed: kubectl get failed"
      echo "Release failed!"
      exit 1
    fi

    echo "The List of resources found by 'kubectl get statefulset,deployment -n ${arg_ns} --no-headers -l ${arg_label}=${arg_release_name}'"
    echo "$check_resources"
    echo

    need_wait="false"
    while IFS= read -r line; do
      if [[ "$line" =~ "No resources found" ]]; then
        echo "No resources found by 'kubectl get statefulset,deployment -n ${arg_ns} --no-headers -l ${arg_label}=${arg_release_name}'"
        echo "Please check filter label, change if needed"
        echo "Release failed."
        exit 1
      fi
  
      read -a arr <<< "$line"
      if [[ "${arr[0]}" =~ ^deployment.apps ]]; then
        deployment_rollout_check ${arr[*]}
        ret=$?
        if [[ $ret -eq 0 ]]; then
          continue
        elif [[ $ret -eq 1 ]]; then
          need_wait=true
        elif [[ $ret -eq 2 ]]; then
          echo "Release failed!"
          exit 1
        fi 
      elif [[ "${arr[0]}" =~ ^statefulset.apps ]]; then
        statefulset_rollout_check ${arr[*]}
        ret=$?
        if [[ $ret -eq 0 ]]; then
          continue
        elif [[ $ret -eq 1 ]]; then
          need_wait=true
        elif [[ $ret -eq 2 ]]; then
          echo "Release failed!"
          exit 1
        fi
      fi
    done < <(echo "$check_resources")

    if [[ $need_wait = "true" ]]; then
      echo "Check progress: pods are creating, waiting for ready"
      sleep 5
    else
      echo "Release succeeded!"
      exit 0
    fi
  done

  echo "Rollout failed, timeout wait for pods to be available, check rollout status."
  echo "Release failed!"
  exit 1
}

function deployment_rollout_check() 
{
  echo "----Check $1 rollout status" 
  type_with_name=$1
  deployment_name=$(echo $1 | cut -d "/" -f 2)
  replicas=$(echo $2 | cut -d "/" -f 2)
  up_to_date=$3
  available=$4
  echo "rollout status is ${up_to_date}(up-to-date), ${available}(available) out of replicas ${replicas}"
  
  new_replicaset=$(kubectl describe -n "${arg_ns}" "${type_with_name}"  | grep '^NewReplicaSet' | awk '{print $2}')
  if [[ $? -ne 0 ]]; then
    echo "Check failed: kubectl describe failed"
    echo "Release failed!"
    exit 1
  fi

  # Print both old and new pods on screen to give better context
  for wait_pods_count in {1..3}; do
    pod_list=$(kubectl get pods -n "${arg_ns}" -l "${arg_label}=${arg_release_name}" --sort-by=.metadata.creationTimestamp | grep "^${deployment_name}-" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "Check failed: kubectl describe failed"
      echo "Release failed!"
      exit 1
    fi

    echo "pod list using filter ${arg_label}=${arg_release_name}:"
    echo "$pod_list"
    echo
    if [[ "$pod_list" =~ "No resources found" ]]; then
      echo "No resources found by 'kubectl get pods -n ${arg_ns} -l ${arg_label}=${arg_release_name}'"
      echo "Either pods are being created or filter label need to be checked."
      if [[ $wait_pods_count -eq 3 ]]; then
        return 2
      fi
      echo "Retry $wait_pods_count times..."
      sleep 3
      continue
    fi
    break
  done

  new_pod_list=$(echo "$pod_list" | grep "${new_replicaset}")
  all_pod_count=$(echo "$pod_list" | wc -l)

  # All pods are available
  if [[ $replicas -eq $up_to_date ]] && [[ $replicas -eq $available ]] && [[ $replicas -eq $all_pod_count ]]; then
    echo "Check passed."
    echo "Rollout succeeded!"
    return 0
  fi

  # Not all pods are available, check status, release is marked as failed if pod need human intervention
  if echo "$new_pod_list" | awk '{print $3}' | grep -q -E "${UNRECOVERABLE_STATUS}"; then
    echo "Rollout failed, possibly new pods ${new_replicaset}-***** in status that need to to be checked and fixed manually by your team."
    return 2
  fi

  return 1
}

function statefulset_rollout_check()
{
  echo "----Check $1 rollout status" 
  type_with_name=$1
  statefulset_name=$(echo $1 | cut -d "/" -f 2)
  replicas=$(echo $2 | cut -d "/" -f 2)
  available=$(echo $2 | cut -d "/" -f 1)
  echo "rollout status is ${available}(available) out of replicas ${replicas}"
  
  # Print both old and new pods on screen to give better context
  for wait_pods_count in {1..3}; do
    pod_list=$(kubectl get pods -n "${arg_ns}" -l "${arg_label}=${arg_release_name}" --sort-by=.metadata.creationTimestamp | grep "^${statefulset_name}-" 2>&1)
    echo "pod list using filter ${arg_label}=${arg_release_name}:"
    echo "$pod_list"
    echo
    if [[ "$pod_list" =~ "No resources found" ]]; then
      echo "No resources found by 'kubectl get pods -n ${arg_ns} -l ${arg_label}=${arg_release_name}'"
      echo "Either pods are being created or filter label need to be checked."
      if [[ $wait_pods_count -eq 3 ]]; then
        return 2
      fi
      echo "Retry $wait_pods_count times..."
      sleep 3
      continue
    fi
    break
  done

  # All pods are available
  if [[ $replicas -eq $available ]]; then
    echo "Check Passed."
    echo "Rollout succeeded!"
    return 0
  fi

  # Not all pods are available, check status, release is marked as failed if pod need human intervention
  if echo "$pod_list" | awk '{print $3}' | grep -q -E "${UNRECOVERABLE_STATUS}"; then
    echo "Rollout failed, possibly pods ${statefulset_name}-* in status that need to to be checked and fixed manually by your team."
    return 2
  fi

  return 1
}

arg_release_name=""
arg_ns=""

SHORT=r:,n:,l:,h
LONG=help
OPTS=$(getopt --options $SHORT --longoptions $LONG -n "$0" -- "$@")
[ $? -ne 0 ] && exit 1

eval set -- "$OPTS"

while :
do
  case "$1" in
    -r )
      arg_release_name="$2"
      if [[ $arg_release_name = "" ]]; then
        echo "-r option can not be empty"
        help
        exit 1
      fi
      shift 2
      ;;
    -n )
      arg_ns="$2"
      shift 2
      ;;
    -l )
      arg_label="$2"
      shift 2
      ;;
    -h | --help)
      help
      exit 2
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Internal Error!"
      exit 1
      ;;
  esac
done

if [[ $arg_release_name = "" ]]; then
  echo "release name can not be empty, specify -r in command line"
  help
  exit 1
fi

if [[ $arg_label = "" ]]; then
  arg_label=${DEFAULT_FILTER_LABEL}
fi

release_existence_check
helm_status_check
rollout_check
