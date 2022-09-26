# helm-release-check
A script to check helm release and wait for all pods available. 

# Basic
On mac, install gnu-getopt before use:   
```
brew install gnu-getopt
```

This script track the pods with label app.kubernetes.io/name according to  [Recommended Labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/).

Release pods with Pending|ImagePullBackOff|CreateContainerConfigError|CrashLoopBackOff status will be considered as non-recoverable and fail immediately.

# Usage
Use it after helm install/upgrade or helmfile sync.   
```
# Use with default filter label app.kubernetes.io/name
./helm-release-check.sh -n default -r hello-world

# Use with custom filter label app
./helm-release-check.sh -n default -r hello-world -l app
```


# helm wait VS helm-release-check
* This script will check the pods status and fail the release if pods stuck in some kind of status which need to be fixed manually. Instead of waiting long period until timeout.
* This script will display the rollout progress on terminal just as you type 'kubectl get pod' on server. Give more clear context why the release is marked as failed. 


