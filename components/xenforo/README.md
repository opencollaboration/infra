# OpenCollab Forum (XenForo)

Deploys XenForo with its add-ons on `opencollab.dev`, and a 3-node MySQL group
replication cluster managed by the Percona Operator for MySQL.

## Image

The image is built by
[xenforo-packaging](https://github.com/opencollaboration/xenforo-packging) and
pushed to the `xenforo` image stream in this namespace on the cluster's internal
registry. It contains the licensed XenForo source, so it is not published
anywhere else. Pushing `:latest` rolls out the deployment through its image
trigger.

The workflow pushes with the `xenforo-image-pusher` service account, which can
only push to image streams in this namespace. After the first sync, copy its
token into the `OPENSHIFT_REGISTRY_TOKEN` secret of the xenforo-packaging repo:

```shell
oc get secret xenforo-image-pusher-token -n opencollab -o jsonpath='{.data.token}' \
  | base64 -d \
  | gh secret set OPENSHIFT_REGISTRY_TOKEN -R opencollaboration/xenforo-packging
```

Then run the workflow (Actions → Build image → Run workflow) to push the first
image; the pod stays in `ImagePullBackOff` until then.

## Database password

The `xenforo-db` secret is **not** managed by this repository and has to be
applied to the cluster manually before the first sync. It holds the password
of the `xenforo` database user. The `create-database` init container creates the user (and resets its password to
this value on every start), so keep it to characters that need no SQL quoting:

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

A new image rolls out as soon as the workflow pushes it. Once the new pod is
running, apply the upgrade to the database and compiled code on the volumes:

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
