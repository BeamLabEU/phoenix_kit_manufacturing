defmodule PhoenixKitManufacturing.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and get
  excluded when the test DB isn't available, matching the rest of the suite.

  ## Example

      defmodule PhoenixKitManufacturing.Web.MachinesLiveTest do
        use PhoenixKitManufacturing.LiveCase

        test "renders the machines page", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")
          assert html =~ "Machines"
        end
      end

  ## Scope assigns

  The module's LiveViews read `socket.assigns[:phoenix_kit_current_scope]`
  for activity-log actor attribution. Tests can plug a fake scope via
  `put_test_scope/2` (which stashes it in the session for the test
  `:assign_scope` `on_mount` hook to read back).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitManufacturing.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitManufacturing.ActivityLogAssertions
      import PhoenixKitManufacturing.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitManufacturing.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  The module's LiveViews attribute activity logs to
  `socket.assigns[:phoenix_kit_current_scope].user.uuid`. Core helpers such
  as `Scope.has_module_access?/2` pattern-match on
  `%PhoenixKit.Users.Auth.Scope{}`, so a plain map won't satisfy them.

  ## Options

    * `:user_uuid` — defaults to a fresh UUID
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role atoms; `[:owner]` makes `admin?/1` true
    * `:permissions` — list of module-key strings; `["manufacturing"]`
      grants access to the module
    * `:authenticated?` — defaults to `true`
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, [:owner])
    permissions = Keyword.get(opts, :permissions, ["manufacturing"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: MapSet.new(roles),
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the test
  `:assign_scope` `on_mount` hook can put it on socket assigns at mount
  time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
