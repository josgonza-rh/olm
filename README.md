# OLM

The Operator Lifecycle Manager (OLM) helps users install, update, and manage the lifecycle of all Operators and their associated services running across their clusters.

When OpenShift Container Platform is installed on restricted networks, also known as a disconnected cluster, Operator Lifecycle Manager (OLM) can no longer use the default OperatorHub sources because they require full Internet connectivity. Cluster administrators can disable those default sources and create local mirrors so that OLM can install and manage Operators from the local sources instead.

> ![WARNING](img/warning-icon.png) **WARNING**: 	
> While OLM can manage Operators from local sources, the ability for a given Operator to run successfully in a restricted network still depends on 
> the Operator itself. The Operator must:
> 
> - List any related images, or other container images that the Operator might require to perform their functions, in the `relatedImages` parameter 
> of its ClusterServiceVersion (CSV) object.
> 
> - Reference all specified images by a digest (SHA) and not by a tag.
> 
> See the following Red Hat Knowledgebase Article for a list of Red Hat Operators that support running in disconnected mode: [Red Hat Operators Supported in Disconnected Mode](https://access.redhat.com/articles/4740011)


## Prerequisites

The following prerequisites are needed to go ahead with the OLM custom catalogs maintenance:

- Internet access (or at least access to the public Red Hat registries)
- `podman` version 1.4.4+
- `oc` version 4.5+ **[1]**
- Access to mirror registry that supports `Docker v2-2`
- [grpcurl](https://github.com/fullstorydev/grpcurl) (only for testing purposes)
- `sqlite`
- Access to the OpenShift cluster with a `cluster-admin` user (in the current session/terminal).

**[1]** [Bug 1812753](https://bugzilla.redhat.com/show_bug.cgi?id=1812753)- couldn't mirror image in mapping.txt created by oc adm catalog mirror

### Red Hat Container Registry Authentication 

The new registry access model requires you to have a Red Hat login. If you are a customer with entitlements to Red Hat products, you already have an account. This is the same type of account that you use to log into the Red Hat Customer Portal (access.redhat.com) and manage your Red Hat subscriptions.

The workstation with unrestricted network access from you are going to executes the scripts must be authenticated with `registry.redhat.io` so that the base image can be pulled during the build (also you may need to authenticate with the target mirror registry depending on your current configuration).

**On RHEL7**

1. Authenticate with `registry.redhat.io`

    ```
    $ podman login -u myrhusername -p xxxxxxxxxxx https://registry.redhat.io
    $ docker login -u myrhusername -p xxxxxxxxxxx https://registry.redhat.io
    ```

    > ![NOTE](img/note-icon.png) **NOTE**: When you log into the registry, your credentials are stored in your $HOME/.docker/config.json file. Those credentials are used automatically the next time you pull from that registry.

2. Use a `json` credentials file. Here is an example of that file:

    ```
    {
    	"auths": {
    		"registry.redhat.io": {
    			"auth": "xxxxxxxxx"
    		}
    	}
    }
    ```

    > ![NOTE](img/note-icon.png) **TIP**: after a successful login you can obtain the credentials by raising the following command:
    > ```bash
    > podman login registry.redhat.io --get-login
    > ```

    On the `oc adm catalog` | `oc image mirror` commands you can indicate the credentials file you want to use with the flag `-a, --registry-config=`

**On RHEL8** 

You must use the `json` authentication file method as a __login__ command will not store the credentials on the default path (`$HOME/.docker/config.json`).


## Mirror operator catalog

All the work done here is based on the Red Hat official documentation and you may consult in the following link: [Using Operator Lifecycle Manager on restricted networks](https://docs.openshift.com/container-platform/4.5/operators/admin/olm-restricted-networks.html)

Build and mirror the catalog from `redhat-operators` source catalog.

```bash
./${OCP_ENVIRONMENT}/mirror-catalog-image.sh rh`
```

Build and mirror the catalog from `community-operators` source catalog.

```bash
./${OCP_ENVIRONMENT}/mirror-catalog-image.sh co`
```


## Troubleshooting

Forward catalog service port to query information from localhost.

**On OCP** (after deployment)

```bash
oc port-forward service/redhat-operators-disconnected 50051:50051 -n openshift-marketplace
```

**On workstation** (before deploy the image / CatalogSource)

```bash
export INTERNAL_REGISTRY=<YOUR_REGISTRY>
export IMAGE="${INTERNAL_REGISTRY}/olm/redhat-operators:v4.5-v1"

podman pull ${IMAGE}

podman run -p 50051:50051 \
 -it ${IMAGE}
```

Then you can check the following (assuming you choosed `podman` option on you local workstation):

- List all the operators in the catalog.

    ```bash
    grpcurl -plaintext localhost:50051 api.Registry/ListPackages
    ```

- Get information for an operator in a catalog.

    ```bash
    grpcurl -plaintext -d '{"name":"<OPERATOR_NAME>"}' \
        localhost:50051 api.Registry/GetPackage

    ex. 
    grpcurl -plaintext -d '{"name":"servicemeshoperator"}' \
        localhost:50051 api.Registry/GetPackage    
    ```

- Get information for an specific channel.

    ```bash
    grpcurl -plaintext -d '{"pkgName":"<OPERATOR_NAME>", "channelName":"<OPERATOR_CHANNEL>"}' \
        localhost:50051 api.Registry/GetBundleForChannel

    ex.
    grpcurl -plaintext -d '{"pkgName":"servicemeshoperator", "channelName":"1.0"}' \
        localhost:50051 api.Registry/GetBundleForChannel    
    ```

> ![NOTE](img/note-icon.png) **NOTE**: if you want also check the custom `community-operators` catalog, the `grpcurl` commands not vary but a new 
> port-forwarding command is needed:
>
> ```bash
> oc port-forward service/community-operators-disconnected 50051:50051 -n openshift-marketplace
> ```
>
> You can also keep both port forwardings running but you should use different __local__ ports ( [local_port]:50051 ) for each one.
> With `podman` just set the proper value for `IMAGE`, ex. `export IMAGE="${INTERNAL_REGISTRY}/olm/community-operators:v4.5-v1"`

**Some handy `oc` commands:**

List all the installed catalogs in the cluster:

```bash
oc get catalogsource -n openshift-marketplace
```

List all the `PackageManifest` presents in the cluster along with the catalog they belongs to:

```bash
oc get packagemanifest
```

Prints tuples with all available `CSV`s, `Version`s and the versions range to skip from a `PackageManifest`: 

```bash
oc get packagemanifest <package_name> -o jsonpath='{range .status.channels[*]}{"Chanel: "}{.name}{" -- CSV: "}{.currentCSV}{" -- Version: "}{.currentCSVDesc.version}{" -- skipRange: "}{.currentCSVDesc.annotations.olm\.skipRange}{"\n"}'

ex. For Service Mesh
oc get packagemanifest servicemeshoperator -o jsonpath='{range .status.channels[*]}{"Chanel: "}{.name}{" -- CSV: "}{.currentCSV}{" -- Version: "}{.currentCSVDesc.version}{" -- skipRange: "}{.currentCSVDesc.annotations.olm\.skipRange}{"\n"}'
```


## Updating an Operator catalog image

Resources Operator Lifecycle Manager uses to resolve upgrades[1]:

- ClusterServiceVersion (CSV)
- CatalogSource
- Subscription

OLM always installs from the latest version of an appr catalog. As appr catalogs are updated, the latest versions of operators change, and older versions may be removed or altered. This behavior can cause problems maintaining reproducible installs over time.

As of OCP 4.3, Red Hat provided operators are distributed via appr catalogs. Creating a snapshot provides a simple way to use this content without incurring the aforementioned issues (in that case `oc adm catalog build` is a point-in-time export of an Appregistry (appr) type catalog’s content)

After a cluster administrator has configured OperatorHub to use custom Operator catalog images, administrators can keep their OpenShift Container Platform cluster up to date with the latest Operators by capturing updates made to Red Hat’s App Registry catalogs. This is done by building and pushing a new Operator catalog image, then replacing the existing CatalogSource’s `spec.image` parameter with the new image digest.

So at this point, you can resolve OLM `Subscriptions` with a snapshot image by referencing it in a `CatalogSource`:

1. Assuming an `OperatorGroup` exists in namespace `caas-monitoring` that supports your operator and its dependencies, create a CatalogSource using the snapshot digest:

    ```yaml
    apiVersion: operators.coreos.com/v1alpha1
    kind: CatalogSource
    metadata:
      name: community-operators-disconnected
      namespace: openshift-marketplace
    spec:
      displayName: Community Operators (Disconnected)
      image: <YOUR_REGISTRY>/olm/community-operators:v4.5-v2
      sourceType: grpc
      publisher: Manual  
    ```

    > ![NOTE](img/note-icon.png) **NOTE**: you can create a new one if you need to mantain both versions of the catalog.

    > ![WARNING](img/warning-icon.png) It is possible that you do not need to apply the imageContentSourcePolicy.yaml manifest. 
    > Complete a `diff` of the files to determine if changes are necessary.

2. Create a Subscription that resolves the latest available `prometheus` and its dependencies from the snapshot.

    ```yaml
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: prometheus
      namespace: caas-monitoring
    spec:
      channel: "beta"
      source: community-operators-disconnected
      name: prometheus
      sourceNamespace: openshift-marketplace
      installPlanApproval: Manual
    ```

3. Just approve the generated install plan [2]:

    ```bash
    oc patch installplan <install-xxxxx> \
      --namespace caas-monitoring \
      --type merge \
      --patch '{"spec":{"approved":true}}'
    ```


[1] [How do operator upgrades work in Operator Lifecycle Manager (OLM)?](https://github.com/operator-framework/operator-lifecycle-manager/blob/master/doc/design/how-to-update-operators.md)

[2] [Operator Lifecycle Manager workflow](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.5/html-single/operators/index#olm-workflow)
