defmodule Logflare.PubSubRates.Rates do
  @moduledoc false
  alias Phoenix.PubSub
  alias Logflare.PubSubRates.Cache

  require Logger

  use GenServer

  @pool_size Application.compile_env(:logflare, Logflare.PubSub)[:pool_size]

  def start_link(args \\ []) do
    GenServer.start_link(
      __MODULE__,
      args,
      name: __MODULE__
    )
  end

  def init(state) do
    for shard <- 1..@pool_size do
      PubSub.subscribe(Logflare.PubSub, "rates:shard-#{shard}")
    end

    {:ok, state}
  end

  def handle_info({:rates, source_id, rates}, state) do
    Cache.cache_rates(source_id, rates)
    {:noreply, state}
  end
end
