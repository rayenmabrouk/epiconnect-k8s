# cloud-init runs its "once per instance" modules again only if instance-id changes
instance-id: ${NODE_NAME}-${SEED_VERSION}
local-hostname: ${NODE_NAME}
