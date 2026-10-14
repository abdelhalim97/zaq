defmodule Zaq.Repo.Migrations.ScopePersonChannelsToConnector do
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :channel_config_id, references(:channel_configs, on_delete: :nothing)
    end

    flush()
    backfill(repo())

    alter table(:channels) do
      modify :channel_config_id, :bigint, null: false
    end

    drop index(:channels, [:platform, :channel_identifier])

    create unique_index(:channels, [:platform, :channel_config_id, :channel_identifier],
             name: :channels_connector_identifier_index
           )
  end

  def backfill(repo) do
    repo.query!("LOCK TABLE channels, channel_configs IN SHARE ROW EXCLUSIVE MODE")

    %{rows: configs} =
      repo.query!("SELECT id, provider, settings FROM channel_configs WHERE kind = 'retrieval'")

    candidates =
      Enum.map(configs, fn [id, provider, settings] ->
        config = %{id: id, provider: provider, kind: "retrieval", settings: settings || %{}}

        {id,
         %{
           platform: to_string(Zaq.Channels.Bridge.provider_to_bridge_key(provider) || provider),
           incoming?: Zaq.Channels.Bridge.incoming_routing(config).incoming?
         }}
      end)

    %{rows: channels} =
      repo.query!("SELECT id, platform FROM channels WHERE channel_config_id IS NULL ORDER BY id")

    # Validate all origins before writing. Disabled/archived connectors still
    # count; prefer receiving origins, falling back to a sole sending origin.
    assignments =
      Enum.map(channels, fn [id, platform] ->
        matching = Enum.filter(candidates, fn {_, profile} -> profile.platform == platform end)
        receiving = Enum.filter(matching, fn {_, profile} -> profile.incoming? end)
        origins = if receiving == [], do: matching, else: receiving

        case origins do
          [{config_id, _}] ->
            {id, config_id}

          _ ->
            raise "PersonChannel connector backfill requires exactly one origin; channel ID: #{id}"
        end
      end)

    Enum.each(assignments, fn {id, config_id} ->
      repo.query!("UPDATE channels SET channel_config_id = $1 WHERE id = $2", [config_id, id])
    end)
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM channels
        GROUP BY platform, channel_identifier HAVING COUNT(*) > 1
      ) THEN
        RAISE EXCEPTION 'Cannot remove connector scope with colliding PersonChannel identities';
      END IF;
    END $$
    """

    drop index(:channels, [:platform, :channel_config_id, :channel_identifier],
           name: :channels_connector_identifier_index
         )

    create unique_index(:channels, [:platform, :channel_identifier])

    alter table(:channels) do
      remove :channel_config_id
    end
  end
end
