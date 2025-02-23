defmodule LogflareWeb.Api.Partner.AccountController do
  use LogflareWeb, :controller

  alias Logflare.Partners
  alias Logflare.Billing.BillingCounts
  alias Logflare.Auth
  action_fallback(LogflareWeb.Api.FallbackController)
  @allowed_fields [:api_quota, :company, :email, :name, :phone, :token]
  def index(%{assigns: %{partner: partner}} = conn, _params) do
    with users <- Partners.list_users_by_partner(partner) do
      allowed_response = Enum.map(users, &sanitize_response/1)
      json(conn, allowed_response)
    end
  end

  def create(%{assigns: %{partner: partner}} = conn, params) do
    with {:ok, user} <- Partners.create_user(partner, params) do
      {:ok, %{token: token}} = Auth.create_access_token(user)

      conn
      |> put_status(201)
      |> json(%{user: user, api_key: token})
    end
  end

  def get_user(%{assigns: %{partner: partner}} = conn, %{"user_token" => user_token}) do
    with user when not is_nil(user) <- Partners.get_user_by_token(partner, user_token) do
      allowed_response = sanitize_response(user)
      json(conn, allowed_response)
    end
  end

  def get_user_usage(%{assigns: %{partner: partner}} = conn, %{"user_token" => user_token}) do
    with user when not is_nil(user) <- Partners.get_user_by_token(partner, user_token) do
      end_date = DateTime.utc_now()

      start_date =
        end_date
        |> then(&Date.new!(&1.year, &1.month, &1.day))
        |> Date.beginning_of_month()
        |> DateTime.new!(~T[00:00:00])

      usage = BillingCounts.cumulative_usage(user, start_date, end_date)
      json(conn, %{usage: usage})
    end
  end

  def delete_user(%{assigns: %{partner: partner}} = conn, %{"user_token" => user_token}) do
    with user when not is_nil(user) <- Partners.get_user_by_token(partner, user_token),
         {:ok, user} <- Partners.delete_user(partner, user) do
      allowed_response = sanitize_response(user)

      conn
      |> put_status(204)
      |> json(allowed_response)
    end
  end

  defp sanitize_response(user) do
    Enum.reduce(@allowed_fields, %{}, fn key, acc -> Map.put(acc, key, Map.get(user, key)) end)
  end
end
