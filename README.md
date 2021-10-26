# k8s-poc

## LOCAL DEVELOPMENT

1. Set `K8S_LOCAL=true` in your environment
2. Set `K8S_TOKEN=<your token>`
   * to get your token do the following
     ```
     kubectl get secret --namespace=<namespace>
     # look for something like "azdev-sa-xxxxxx" that's the <secret-name>
     kubectl get secret <secret_name> -o jsonpath={.data.token} | base64 -d
     ```
