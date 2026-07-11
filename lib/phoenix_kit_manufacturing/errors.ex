defmodule PhoenixKitManufacturing.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by the Manufacturing module's
  public API and used across its LiveViews) to translated human-readable
  strings.

  Keeping UI-facing copy in one place means every "not found" or "delete
  failed" flash reads the same wording. Callers pattern-match on atoms;
  `message/1` wraps each mapping in `gettext/1` at the UI boundary.

  ## Supported reason shapes

    * plain atoms — `:machine_not_found`, `:type_assignment_failed`, etc.
    * strings — passed through unchanged
    * anything else — rendered as `"Unexpected error: <inspect>"`

  ## Example

      iex> PhoenixKitManufacturing.Errors.message(:machine_not_found)
      "Machine not found."
  """

  use Gettext, backend: PhoenixKitManufacturing.Gettext

  @doc "Translates an error reason into a user-facing string via gettext."
  @spec message(term()) :: String.t()
  def message(:machine_not_found), do: gettext("Machine not found.")
  def message(:machine_type_not_found), do: gettext("Machine type not found.")
  def message(:machine_delete_failed), do: gettext("Failed to delete machine.")
  def message(:machine_type_delete_failed), do: gettext("Failed to delete machine type.")

  def message(:type_assignment_failed),
    do: gettext("Saved but failed to update type assignments.")

  def message(:unexpected), do: gettext("An unexpected error occurred.")

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
