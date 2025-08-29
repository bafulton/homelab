# homelab/kubernetes


## Sync order

ArgoCD supports explicit ordering of which resources are synced first.
In our case, we will use the following priority/ordering:

   "0"  Namespaces
   "10" Infra apps
   "20" Everything else
