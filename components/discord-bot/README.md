# OpenCollab Discord Bot

Deploys the [OpenCollab Discord bot](https://github.com/opencollab-incubator/OpenCollabDiscordBot)
into the `opencollab` namespace.

## Configuration secret

The bot reads all of its configuration (Discord token, database credentials, etc.)
from a `bot.properties` file, which is mounted from the `discord-bot-properties`
secret. This secret is **not** managed by this repository — for now it has to be
applied to the cluster manually:

1. Create a `bot.properties` file based on
   [`bot.properties.example`](https://github.com/opencollab-incubator/OpenCollabDiscordBot/blob/master/bot.properties.example).
2. Apply it to the cluster:

   ```shell
   kubectl create secret generic discord-bot-properties \
     --namespace opencollab \
     --from-file=bot.properties
   ```

In the future this secret should be migrated to External Secrets instead of
being applied manually.

## Database

When using SQLite (`db-type: sqlite`), set `db-database: /opt/app/data/bot.db`
so the database lands on the `discord-bot-data` persistent volume and survives
pod restarts. Any other path is ephemeral. MySQL can be used instead by
setting the `db-*` options accordingly.
