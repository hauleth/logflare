defmodule Logflare.SourcesTest do
  @moduledoc false
  use Logflare.DataCase

  import Logflare.Factory

  alias Logflare.Backends.SourceBackend
  alias Logflare.Google.BigQuery
  alias Logflare.Google.BigQuery.GenUtils
  alias Logflare.Source
  alias Logflare.Source.RecentLogsServer, as: RLS
  alias Logflare.Sources
  alias Logflare.Sources.Counters
  alias Logflare.SourceSchemas
  alias Logflare.Users

  describe "create_source/2" do
    setup do
      user = insert(:user)
      insert(:plan, name: "Free")
      %{user: user}
    end

    test "creates a source for a given user and creates schema", %{
      user: %{id: user_id} = user
    } do
      assert {:ok, source} = Sources.create_source(%{name: TestUtils.random_string()}, user)
      assert %Source{user_id: ^user_id, v2_pipeline: false} = source
      assert SourceSchemas.get_source_schema_by(source_id: source.id)
    end

    test "if :postgres_backend_url is set and single tenant, creates a source with a postgres backend",
         %{
           user: %{id: user_id} = user
         } do
      %{username: username, password: password, database: database, hostname: hostname} =
        Application.get_env(:logflare, Logflare.Repo) |> Map.new()

      url = "postgresql://#{username}:#{password}@#{hostname}/#{database}"

      previous_postgres_backend_adapter =
        Application.get_env(:logflare, :postgres_backend_adapter)

      previous_single_tenant = Application.get_env(:logflare, :single_tenant)

      Application.put_env(:logflare, :postgres_backend_adapter, url: url)
      Application.put_env(:logflare, :single_tenant, true)

      on_exit(fn ->
        Application.put_env(
          :logflare,
          :postgres_backend_adapter,
          previous_postgres_backend_adapter
        )

        Application.put_env(:logflare, :single_tenant, previous_single_tenant)
      end)

      assert {:ok, source} = Sources.create_source(%{name: TestUtils.random_string()}, user)
      assert %Source{user_id: ^user_id, v2_pipeline: true} = source
      assert [%SourceBackend{type: :postgres}] = Logflare.Backends.list_source_backends(source)
    end
  end

  describe "list_sources_by_user/1" do
    test "lists sources for a given user" do
      user = insert(:user)
      insert(:source, user: user)
      assert [%Source{}] = Sources.list_sources_by_user(user)
      assert [] == insert(:user) |> Sources.list_sources_by_user()
    end
  end

  describe "get_bq_schema/1" do
    setup do
      user = Users.get_by(email: System.get_env("LOGFLARE_TEST_USER_WITH_SET_IAM"))
      source = insert(:source, token: TestUtils.gen_uuid(), rules: [], user_id: user.id)

      Source.BigQuery.Schema.start_link(%RLS{
        source_id: source.token,
        plan: %{limit_source_fields_limit: 500}
      })

      %{source: source}
    end

    @tag :failing
    test "fetches schema for given source", %{source: source, user: user} do
      source_id = source.token

      %{
        bigquery_table_ttl: bigquery_table_ttl,
        bigquery_dataset_location: bigquery_dataset_location,
        bigquery_project_id: bigquery_project_id,
        bigquery_dataset_id: bigquery_dataset_id
      } = GenUtils.get_bq_user_info(source_id)

      BigQuery.init_table!(
        user.id,
        source_id,
        bigquery_project_id,
        bigquery_table_ttl,
        bigquery_dataset_location,
        bigquery_dataset_id
      )

      schema = %GoogleApi.BigQuery.V2.Model.TableSchema{
        fields: [
          %GoogleApi.BigQuery.V2.Model.TableFieldSchema{
            categories: nil,
            description: nil,
            fields: nil,
            mode: "NULLABLE",
            name: "event_message",
            policyTags: nil,
            type: "STRING"
          },
          %GoogleApi.BigQuery.V2.Model.TableFieldSchema{
            categories: nil,
            description: nil,
            fields: nil,
            mode: "NULLABLE",
            name: "id",
            policyTags: nil,
            type: "STRING"
          },
          %GoogleApi.BigQuery.V2.Model.TableFieldSchema{
            categories: nil,
            description: nil,
            fields: nil,
            mode: "REQUIRED",
            name: "timestamp",
            policyTags: nil,
            type: "TIMESTAMP"
          }
        ]
      }

      assert {:ok, _} =
               BigQuery.patch_table(source_id, schema, bigquery_dataset_id, bigquery_project_id)

      {:ok, left_schema} = Sources.get_bq_schema(source)
      assert left_schema == schema
    end
  end

  describe "preload_for_dashboard/1" do
    setup do
      Counters.start_link()

      %{user: insert(:user)}
    end

    test "preloads required fields", %{user: user} do
      sources = insert_list(3, :source, %{user: user})
      sources = Sources.preload_for_dashboard(sources)

      assert Enum.all?(sources, &Ecto.assoc_loaded?(&1.user))
      assert Enum.all?(sources, &Ecto.assoc_loaded?(&1.rules))
      assert Enum.all?(sources, &Ecto.assoc_loaded?(&1.saved_searches))
    end

    test "sorts data by name and favorite flag", %{user: user} do
      source_1 = insert(:source, %{user: user, name: "C"})
      source_2 = insert(:source, %{user: user, name: "B", favorite: true})
      source_3 = insert(:source, %{user: user, name: "A"})
      sources = Sources.preload_for_dashboard([source_1, source_2, source_3])

      assert Enum.map(sources, & &1.name) == Enum.map([source_2, source_3, source_1], & &1.name)
    end
  end
end
