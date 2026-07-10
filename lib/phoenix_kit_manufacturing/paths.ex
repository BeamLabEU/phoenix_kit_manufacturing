defmodule PhoenixKitManufacturing.Paths do
  @moduledoc """
  Centralized path helpers for the Manufacturing module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale
  handling. Never hardcode `"/admin/manufacturing"` in a LiveView or template
  — use these helpers instead so URL prefix changes only need updating here.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/manufacturing"

  @doc "Manufacturing dashboard."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)
end
