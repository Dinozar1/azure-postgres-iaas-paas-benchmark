#cloud-config
package_update: true
package_upgrade: true

packages:
  - postgresql-${postgresql_version}
  - postgresql-contrib-${postgresql_version}

write_files:
  - path: /opt/provision/format-mount-disk.sh
    permissions: '0700'
    content: |
      #!/bin/bash
      set -euo pipefail
      DEVICE=/dev/disk/azure/scsi1/lun0
      MOUNT_POINT=/mnt/pgdata

      mkfs.ext4 -F "$DEVICE"
      mkdir -p "$MOUNT_POINT"
      mount "$DEVICE" "$MOUNT_POINT"
      UUID=$(blkid -s UUID -o value "$DEVICE")
      echo "UUID=$UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
      chown postgres:postgres "$MOUNT_POINT"

runcmd:
  - systemctl stop postgresql
  - bash /opt/provision/format-mount-disk.sh
  - pg_dropcluster --stop ${postgresql_version} main || true
  - mkdir -p /mnt/pgdata/${postgresql_version}
  - chown postgres:postgres /mnt/pgdata/${postgresql_version}
  - pg_createcluster ${postgresql_version} main --datadir=/mnt/pgdata/${postgresql_version}/main -- --auth-local=peer --auth-host=md5
  - sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" /etc/postgresql/${postgresql_version}/main/postgresql.conf
  - echo "host all all ${allowed_client_address_space} md5" >> /etc/postgresql/${postgresql_version}/main/pg_hba.conf
  - systemctl restart postgresql
  - sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${postgres_admin_password}';"
  - sudo -u postgres createdb pgbench_db