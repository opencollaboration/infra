# OpenCollab Forum (XenForo)

Deploys XenForo with its add-ons on `opencollab.dev`, using the image built by
[xenforo-packaging](https://github.com/opencollaboration/xenforo-packging), and a
3-node MySQL group replication cluster managed by the Percona Operator for MySQL.

## Secrets

Two secrets are **not** managed by this repository and have to be applied to
the cluster manually before the first sync:

1. `ghcr-pull`: pulls the image, which is private because it contains the
   licensed XenForo source. It needs a token with `read:packages` on the
   `opencollaboration/xenforo` package:

   ```shell
   kubectl create secret docker-registry ghcr-pull \
     --namespace opencollab \
     --docker-server=ghcr.io \
     --docker-username=<github user> \
     --docker-password=<token>
   ```

2. `xenforo-db`: the password of the `xenforo` database user. The
   `create-database` init container creates the user (and resets its password
   to this value on every start), so keep it to characters that need no SQL
   quoting:

   ```shell
   kubectl create secret generic xenforo-db \
     --namespace opencollab \
     --from-literal=password="$(openssl rand -hex 24)"
   ```

The operator generates the MySQL system users (including `root`) into
`xenforo-mysql-secrets`.

## Installing

On the first deployment, install XenForo and the add-ons from the pod:

```shell
oc exec -it -n opencollab deploy/xenforo -- php cmd.php xf:install
oc exec -it -n opencollab deploy/xenforo -- php cmd.php xf:addon-install-batch <add-on ids>
```

Then configure outgoing email (SMTP) under Setup → Options → Email options;
the image has no local mail server.

## Upgrading

Change the image tag in `base/deployment.yaml`. Once the new pod is running,
apply the upgrade to the database and compiled code on the volumes:

```shell
oc exec -it -n opencollab deploy/xenforo -- php cmd.php xf:upgrade
oc exec -it -n opencollab deploy/xenforo -- php cmd.php xf:addon-upgrade <add-on id>  # for each updated add-on
```

Add-ons installed through the admin panel are lost when the pod restarts;
add them to `image/addons.txt` in xenforo-packaging instead.

## Storage and backups

- `xenforo-data` and `xenforo-internal-data` hold user content and attachment
  files. They are not backed up by the operator; attachments live there and
  their records in MySQL, so restore both together.
- The database is backed up daily (14 kept) to the in-cluster Ceph bucket
  `opencollab-xenforo-mysql-backups`. That is not off-site.
