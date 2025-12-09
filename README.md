# About this fork

This work is a fork of https://github.com/siamaksade/openshift-cicd-demo for the use case of on-premises virtualized OpenShift environments for demo purposes, where you wouldn't have a paid certificate or instead you are relying on the default Ingress CA. Perhaps you installed OpenShift on an SNO environment or even you're using OpenShift Local (AKA CRC) for your demo.

If using the demo on Codeready Containers (OpenShift Local) on Windows 11, set your WSL2 to use mirror network mode so that the ingress controller can be reached from the host. This is done by creating the following in the WSL2 config file `$HOME/.wslconfig`.

```ini
[wsl2]
networkingMode=mirrored
```

The only pre-requisite in this regard is that you obtain your ingress default CA (or your custom CA) and then add that CA to the proxy/cluster object in OpenShift before installing this demo, besides other pre-requisites that are documented in this README file.

This is the procedure you can follow on RHEL or RHEL derivatives. This was tested on RHEL 9.

```shell
oc get secret/router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' |base64 -d > ingress-ca.crt
# For Fedora:
sudo cp ingress-ca.crt /etc/pki/ca-trust/source/anchors
sudo update-ca-trust

# For Ubuntu:
sudo cp ingress-ca.crt /usr/local/share/ca-certificates
sudo update-ca-certificates

oc create configmap custom-ca --from-file ca-bundle.crt=./ingress-ca.crt -n openshift-config
oc patch proxy/cluster --type=merge -p '{"spec":{"trustedCA":{"name":"custom-ca"}}}'

# wait for the pods to be restarted

watch oc get pods -n openshift-apiserver
```

Also import the CA to your local machine, so you can access the OpenShift console and the Gitea instance without certificate errors.


# CI/CD Demo with Tekton and Argo CD on OpenShift

This repo is a CI/CD demo using [Tekton Pipelines](http://www.tekton.dev) for continuous integration and [Argo CD](https://argoproj.github.io/argo-cd/) for continuous delivery on OpenShift which builds and deploys the [Spring PetClinic](https://github.com/spring-projects/spring-petclinic) sample Spring Boot application. This demo creates:

* 3 namespaces for CI/CD, DEV and STAGE projects
* 1 Tekton pipeline for building the application image on every Git commit and pull-request
* Argo CD (login with OpenShift credentials)
* Gitea git server (username/password: `gitea`/`openshift`)
* Sonatype Nexus (username/password: `admin`/`admin123`)
* SonarQube (username/password: `admin`/`admin`)

<p align="center">
  <img width="580" src="docs/images/projects.svg">
</p>

## Tested Configuration

* OpenShift GitOps 1.16
* OpenShift Pipelines 1.18

## Continuous Integration

On every push or pull-request to the `spring-petclinic` git repository on Gitea git server, the following steps are executed within the Tekton pipeline:

1. Code is cloned from Gitea git server and the unit-tests are run
1. Unit tests are executed and in parallel the code is analyzed by SonarQube for anti-patterns, and a dependency report is generated
1. Application is packaged as a JAR and released to Sonatype Nexus snapshot repository
1. A container image is built in DEV environment using S2I, and pushed to OpenShift internal registry, and tagged with `spring-petclinic:[branch]-[commit-sha]` and `spring-petclinic:latest`
1. Kubernetes manifests are updated in the Git repository with the image digest that was built within the pipeline
1. A pull-requested is created on config repo for merging the image digest update into the STAGE environment

![Pipeline Diagram](docs/images/ci-pipeline.svg)

## Continuous Delivery

Argo CD continuously monitor the configurations stored in the Git repository and uses [Kustomize](https://kustomize.io/) to overlay environment specific configurations when deploying the application to DEV and STAGE environments.

![Continuous Delivery](docs/images/cd.png)

## Install Demo

1. Get an OpenShift cluster via https://try.openshift.com
1. Install OpenShift Pipelines and OpenShift GitOps operators 
1. Download [OpenShift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/) and [OpenShift Pipelines CLI](https://mirror.openshift.com/pub/openshift-v4/clients/pipeline/latest/)
1. Run the install script

    ```text
    $ oc new-project demo
    $ git clone https://github.com/siamaksade/openshift-cicd-demo
    $ demo.sh install
    ```
## Credentials
* Nexus: `admin`/`admin123`
* Gitea: `gitea`/`openshift`
* SonarQube: `admin`/`sonarqube`

## Demo Instructions
1. Go to spring-petclinic Git repository in Gitea
1. Log into Gitea with username/password: `gitea`/`openshift`
1. Edit a file in the repository and commit to trigger the pipeline. Alternatively, create a pull-request instead to see the result on the deployed app before merging.
1. Check the pipeline run logs in Dev Console or Tekton CLI:

   ```text
   $ opc pac logs -n demo-cicd
   ```

1. Once the pipeline finishes successfully, the image reference in the `spring-petclinic-config/environments/dev` are updated with the new image digest and automatically deployed to the DEV environment by Argo CD. If Argo CD hasn't polled the Git repo for changes yet, click on the "Refresh" button on the Argo CD application.

1. Login into Argo CD dashboard and check the sync history of `dev-spring-petclinic` application to verify the recent deployment

1. Go to the pull requests tab on `spring-petclinic-config` Git repository in Gitea and merge the pull-requested that is generated for promotion from DEV to STAGE

1. Check the sync history of `stage-spring-petclinic` application in Argo CD dashboard to verify the recent deployment to the staging environment. If Argo CD hasn't polled the Git repo for changes yet, click on the "Refresh" button on the Argo CD application.

![Gitea Pull Request](docs/images/gitea.png)

![Pipeline Diagram](docs/images/pipelines-3.png)

![Pipeline Diagram](docs/images/pipelines-2.png)

![Pipeline Diagram](docs/images/pipelines-1.png)

![Argo CD](docs/images/argocd.png)

![Promotion Pull-Request](docs/images/promote-pr.png)


## Troubleshooting

**Q: Why am I getting `unable to recognize "tasks/task.yaml": no matches for kind "Task" in version "tekton.dev/v1beta1"` errors?**

You might have just installed the OpenShift Pipelines operator on the cluster and the operator has not finished installing Tekton on the cluster yet. Wait a few minutes for the operator to finish and then install the demo.


**Q: why do I get `Unable to deploy revision: permission denied` when I manually sync an Application in Argo CD dashboard?**

When you log into Argo CD dashboard using your OpenShift credentials, your access rights in Argo CD will be assigned based on your access rights in OpenShift. The Argo CD instance in this demo is [configured](https://github.com/siamaksade/openshift-cicd-demo/blob/main/argo/argocd.yaml#L21) to map `kubeadmin` and any users in the `ocp-admins` groups in OpenShift to an Argo CD admin user. Note that `ocp-admins` group is not available in OpenShift by default. You can create this group using the following commands:

```
# create ocp-admins group
oc adm groups new ocp-admins

# give cluster admin rightsto ocp-admins group
oc adm policy add-cluster-role-to-group cluster-admin ocp-admins

# add username to ocp-admins group
oc adm groups add-users ocp-admins USERNAME
```
