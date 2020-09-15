# Terraform all the things!

## Requirements
You'll need Terraform and the Kubernetes CLI. The easiest way to install is via [Homebrew](http://brew.sh).

```
brew install terraform
brew install kubernetes-cli
```

## Infrastructure Configuration
To install or update the infrastructure, dashboard and boutique app:

1. `cd` to the appropriate cloud provider directory.
1. run `terraform init` to install the Terraform providers.
1. run `terraform apply` to install the group.

## Kubernetes

During the `terraform apply`, the Kubernetes config file to interact with your cluster will be automatically downloaded to `~/.kube/group-##-config.yaml`. To interact with your cluster:

```
export KUBECONFIG=$KUBECONFIG:~/.kube/group-##-config.yaml
kubectl config use-context do-sfo2-group-##
```


## Creating multiple clusters
Highly recommed creating a new workspace for every group you are creating, if not terraform might overide the previous state when you run apply 
`terraform workspace new 01`

you can also provide the variables needed via a varaible file
`terraform apply  -var-file="group01.tfvars"`

example `.tfvars` file:
```
do_token = ""
group_number = ""
gremlin_team_id = ""
gremlin_team_secret = ""
datadog_apikey = ""
datadog_appkey = ""
```

## Debugging

If you have any issues running terraform, delete your `terraform.tfstate` and run `terraform init` once again. 

You can only name Digital Ocean clusters using lowercase characters, dashes and numbers. 
