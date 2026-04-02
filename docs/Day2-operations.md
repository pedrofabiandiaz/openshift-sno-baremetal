You can perform the postinstallation configuration tasks to configure your environment to meet your needs.

The following lists details these configurations:

* [Configure operating system features](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/machine_configuration/#machine-config-overview): The Machine Config Operator (MCO) manages `MachineConfig` objects. By using the MCO, you can configure nodes and custom resources.  
* [Configure cluster features](https://docs.redhat.com/de/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/post-install-cluster-tasks). You can modify the following features of an OpenShift Container Platform cluster:  
* Image registry — [Local Storage Operator on SNO](LOCAL_STORAGE_OPERATOR_SNO.md)  
* Networking configuration  
* Image build behavior  
* Identity provider  
* The etcd configuration  
* Machine set creation to handle the workloads  
* Cloud provider credential management  
* [Configuring a private cluster](https://docs.redhat.com/de/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/configuring-private-cluster): By default, the installation program provisions OpenShift Container Platform by using a publicly accessible DNS and endpoints. To make your cluster accessible only from within an internal network, configure the following components to make them private:  
* DNS  
* Ingress Controller  
* API server  
* [Perform node operations](https://docs.redhat.com/de/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/post-install-node-tasks): By default, OpenShift Container Platform uses Red Hat Enterprise Linux CoreOS (RHCOS) compute machines. You can perform the following node operations:  
* Add and remove compute machines.  
* Add and remove taints and tolerations.  
* Configure the maximum number of pods per node.  
* Enable Device Manager.  
* [Configure users](https://docs.redhat.com/de/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/post-install-preparing-for-users): Users can authenticate themselves to the API by using OAuth access tokens. You can configure OAuth to perform the following tasks:  
* Specify an identity provider — [HTPasswd identity provider setup](HTPASSWD_IDENTITY_PROVIDER.md).  
* Use role-based access control to define and grant permissions to users — [HTPasswd identity provider setup](HTPASSWD_IDENTITY_PROVIDER.md#6-grant-cluster-roles-optional).  
* Install an Operator from the software catalog.  
* [Configuring alert notifications](https://docs.redhat.com/de/documentation/openshift_container_platform/4.20/html/postinstallation_configuration/configuring-alert-notifications): By default, firing alerts are displayed on the Alerting UI of the web console. You can also configure OpenShift Container Platform to send alert notifications to external systems.