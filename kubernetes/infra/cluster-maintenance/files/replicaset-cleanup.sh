#!/bin/sh
set -eu

keep=${KEEP_PER_DEPLOYMENT:-3}
case "$keep" in
  ''|*[!0-9]*) echo "KEEP_PER_DEPLOYMENT must be a nonnegative integer" >&2; exit 1 ;;
esac

# A single snapshot lets us match ReplicaSets to their Deployment by namespace
# and owner UID. A deleted/recreated Deployment must not inherit the old one's
# retention counter. Only completed, scaled-up rollouts with exactly one active
# ReplicaSet are eligible; a scale-to-zero or in-progress rollout is left alone.
snapshot=$(kubectl get deployments,replicasets -A -o json)
candidates=$(printf '%s' "$snapshot" | jq -r --argjson keep "$keep" '
  [.items[] | select(.kind == "Deployment")] as $deployments
  | [.items[] | select(.kind == "ReplicaSet") | . as $rs
     | .metadata.ownerReferences[]?
     | select(.controller == true and .kind == "Deployment" and .uid != null)
     | {namespace: $rs.metadata.namespace, ownerUid: .uid, rs: $rs}] as $sets
  | $deployments[] as $deployment
  | ($deployment.spec.replicas // 1) as $desired
  | select($desired > 0
      and ($deployment.status.observedGeneration // 0) >= $deployment.metadata.generation
      and ($deployment.status.replicas // 0) == $desired
      and ($deployment.status.updatedReplicas // 0) == $desired
      and ($deployment.status.availableReplicas // 0) == $desired)
  | [$sets[] | select(.namespace == $deployment.metadata.namespace
      and .ownerUid == $deployment.metadata.uid) | .rs] as $owned
  | [$owned[] | select((.spec.replicas // 0) > 0)] as $active
  | select($active | length == 1)
  | $active[0] as $current
  | select($owned | all(.[]; .metadata.uid == $current.metadata.uid
      or ((.spec.replicas // 0) == 0 and (.status.replicas // 0) == 0)))
  | [$owned[] | select(.metadata.uid != $current.metadata.uid)]
  | sort_by([.metadata.creationTimestamp, .metadata.name]) | reverse
  | .[$keep:][]
  | [$deployment.metadata.namespace, $deployment.metadata.name,
     ($deployment.metadata.generation | tostring), $current.metadata.name,
     $current.metadata.uid, .metadata.name, .metadata.uid,
     .metadata.resourceVersion] | @tsv
')

[ -n "$candidates" ] || { echo "No old ReplicaSets to delete"; exit 0; }

printf '%s\n' "$candidates" | while IFS="$(printf '\t')" read -r ns owner generation current_name current_uid name uid version; do
  # Recheck before each delete: the deployment may have rolled out or scaled
  # down after the snapshot. The candidate must still be the same inactive RS.
  deployment=$(kubectl get deployment -n "$ns" "$owner" -o json) || continue
  current=$(kubectl get replicaset -n "$ns" "$current_name" -o json) || continue
  candidate=$(kubectl get replicaset -n "$ns" "$name" -o json) || continue
  if ! jq -en --argjson deployment "$deployment" --argjson current "$current" \
      --argjson candidate "$candidate" --arg generation "$generation" \
      --arg current_uid "$current_uid" --arg uid "$uid" --arg version "$version" '
      ($deployment.metadata.generation | tostring) == $generation
      and ($deployment.spec.replicas // 1) > 0
      and ($deployment.status.observedGeneration // 0) >= $deployment.metadata.generation
      and ($deployment.status.replicas // 0) == ($deployment.spec.replicas // 1)
      and ($deployment.status.updatedReplicas // 0) == ($deployment.spec.replicas // 1)
      and ($deployment.status.availableReplicas // 0) == ($deployment.spec.replicas // 1)
      and $current.metadata.uid == $current_uid
      and ($current.spec.replicas // 0) > 0
      and ([$current.metadata.ownerReferences[]? | select(.controller == true and .kind == "Deployment" and .uid == $deployment.metadata.uid)] | length) == 1
      and $candidate.metadata.uid == $uid
      and $candidate.metadata.resourceVersion == $version
      and ($candidate.spec.replicas // 0) == 0
      and ($candidate.status.replicas // 0) == 0
      and ([$candidate.metadata.ownerReferences[]? | select(.controller == true and .kind == "Deployment" and .uid == $deployment.metadata.uid)] | length) == 1
    ' >/dev/null; then
    echo "Skipping $ns/$name: ownership or rollout changed"
    continue
  fi
  echo "Deleting old ReplicaSet $ns/$name"
  kubectl delete replicaset -n "$ns" "$name" --ignore-not-found
done
