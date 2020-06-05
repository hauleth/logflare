defmodule Logflare.Source.Supervisor do
  @moduledoc """
  Boots up a gen server per source table. Keeps a list of active tables in state.
  """

  use GenServer

  alias Logflare.Repo
  alias Logflare.Sources.Counters
  alias Logflare.Google.BigQuery
  alias Logflare.Source.RecentLogsServer, as: RLS
  alias Logflare.Cluster

  import Ecto.Query, only: [from: 2]

  require Logger

  # TODO: periodically check the database and locally create or delete any sources accordingly

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(source_ids) do
    Process.flag(:trap_exit, true)

    {:ok, source_ids, {:continue, :boot}}
  end

  ## Server

  def handle_continue(:boot, _source_ids) do
    # Start sources with events first
    # Tomorrow only start sources with events in the last day, and auto start recent_log_servers when requests come in if it's not already started
    # Also start recent_log_servers when anything in source route is viewed (plug maybe)

    query =
      from(s in "sources",
        order_by: s.log_events_updated_at,
        select: %{
          token: s.token
        }
      )

    source_ids =
      query
      |> Repo.all()
      |> Enum.map(fn s ->
        {:ok, source} = Ecto.UUID.Atom.load(s.token)
        source
      end)

    # BigQuery Rate limit is 100/second
    Enum.map(source_ids, fn source_id ->
      rls = %RLS{source_id: source_id}
      Supervisor.child_spec({RLS, rls}, id: source_id, restart: :transient)
    end)
    |> Enum.chunk_every(25)
    |> Enum.each(fn x ->
      Logger.info("Sleeping for startup Logflare.Source.Supervisor")
      Process.sleep(2_000)
      Supervisor.start_link(x, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
    end)

    {:noreply, source_ids}
  end

  def handle_cast({:create, source_id}, state) do
    case create_source(source_id) do
      {:ok, _pid} ->
        state = Enum.uniq([source_id | state])
        {:noreply, state}

      {:error, _reason} ->
        Logger.error("Failed to start RecentLogsServer: #{source_id}")

        {:noreply, state}
    end
  end

  def handle_cast({:delete, source_id}, state) do
    case Process.whereis(source_id) do
      nil ->
        {:noreply, state}

      _ ->
        send(source_id, {:stop_please, :shutdown})
        Counters.delete(source_id)

        state = List.delete(state, source_id)
        {:noreply, state}
    end
  end

  def handle_cast({:restart, source_id}, state) do
    case Process.whereis(source_id) do
      nil ->
        case create_source(source_id) do
          {:ok, _pid} ->
            state = Enum.uniq([source_id | state])
            {:noreply, state}

          {:error, _reason} ->
            Logger.error("Failed to start RecentLogsServer: #{source_id}")

            {:noreply, state}
        end

        {:noreply, state}

      _ ->
        send(source_id, {:stop_please, :shutdown})

        Process.sleep(1_000)

        case create_source(source_id) do
          {:ok, _pid} ->
            state = Enum.uniq([source_id | state])
            {:noreply, state}

          {:error, _reason} ->
            Logger.error("Failed to start RecentLogsServer: #{source_id}")

            {:noreply, state}
        end
    end
  end

  def terminate(reason, _state) do
    # Do Shutdown Stuff
    Logger.info("Going Down - #{inspect(reason)} - #{__MODULE__}")
    reason
  end

  ## Public Functions

  def new_source(source_id) do
    # Calling this server doing boot times out due to logs of sources getting created at once and handle_continue blocks
    # GenServer.multi_call(Cluster.Utils.node_list_all(), __MODULE__, {:create, source_id})

    GenServer.abcast(Cluster.Utils.node_list_all(), __MODULE__, {:create, source_id})
  end

  def delete_source(source_id) do
    GenServer.abcast(Cluster.Utils.node_list_all(), __MODULE__, {:delete, source_id})
    BigQuery.delete_table(source_id)

    {:ok, source_id}
  end

  def reset_source(source_id) do
    GenServer.abcast(Cluster.Utils.node_list_all(), __MODULE__, {:restart, source_id})

    {:ok, source_id}
  end

  def delete_all_user_sources(user) do
    Repo.all(Ecto.assoc(user, :sources))
    |> Enum.each(fn s -> delete_source(s.token) end)
  end

  def reset_all_user_sources(user) do
    Repo.all(Ecto.assoc(user, :sources))
    |> Enum.each(fn s -> reset_source(s.token) end)
  end

  defp create_source(source_id) do
    rls = %RLS{source_id: source_id}

    children = [
      Supervisor.child_spec({RLS, rls}, id: source_id, restart: :transient)
    ]

    init_table(source_id)

    Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp init_table(source_id) do
    %{
      user_id: user_id,
      bigquery_table_ttl: bigquery_table_ttl,
      bigquery_project_id: bigquery_project_id,
      bigquery_dataset_location: bigquery_dataset_location,
      bigquery_dataset_id: bigquery_dataset_id
    } = BigQuery.GenUtils.get_bq_user_info(source_id)

    BigQuery.init_table!(
      user_id,
      source_id,
      bigquery_project_id,
      bigquery_table_ttl,
      bigquery_dataset_location,
      bigquery_dataset_id
    )
  end
end
