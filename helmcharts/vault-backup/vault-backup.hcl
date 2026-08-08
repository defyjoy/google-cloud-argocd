# Take a snapshot (backup)
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Optional: leader check used by the backup job
path "sys/leader" {
  capabilities = ["read"]
}

# Force-restore a snapshot
path "sys/storage/raft/snapshot-force" {
  capabilities = ["update"]
}
