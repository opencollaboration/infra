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
